// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

// ---------------------------------------------------------------------------
// 0.8.26 views onto the vendored 0.8.29 contracts.
//
// WHY interfaces instead of imports: `src/FlowstateC1Hook.sol` pins `pragma solidity
// 0.8.26` (exact — it is the version the immutable hook ships at, and the version its
// mined CREATE2 address is derived from), while the real Flowstate contracts pin
// `pragma solidity 0.8.29`. A single Solidity file importing both is an unsatisfiable
// compilation unit. Declaring the market/pool surface locally and instantiating through
// `vm.getCode` keeps the two versions in separate units, so the hook under test is
// byte-identical to the hook that will be deployed.
// ---------------------------------------------------------------------------

interface IFlowstateMarketTest {
    struct Quote {
        bool available;
        uint256 fillableAmount;
        uint256 quoteAmount;
        uint256 feeAmount;
        uint16 feeBps;
        address quoteAsset;
    }

    function initialize(
        address poolBeacon_,
        address beaconProxyTemplate_,
        address priceOracle_,
        address buybackReceiver_,
        address adminMultisig,
        address timelock48,
        address freezeTimelock24,
        address emergencyTimelock12
    ) external;

    // registry / liquidity
    function createPool(address token, uint256 amount, uint16 anchorBandBps)
        external
        returns (address pool);
    function contributeTokens(address pool, uint256 amount, address contributionOwner) external;
    function withdrawTokens(address pool, uint256 amount) external;
    function poolByPair(address token, address quote) external view returns (address);
    function poolBeacon() external view returns (address);
    function priceOracle() external view returns (address);
    function oracleEpoch() external view returns (uint32);
    function buybackReceiver() external view returns (address);

    // trading
    function buyFromPool(address pool, address asset, uint256 amount, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);
    function buyFromPoolExactQuote(address pool, address asset, uint256 quoteIn, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);
    function buyFromPoolExactOut(address pool, address asset, uint256 tokenAmountOut, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);
    function quoteBuyFromPool(address pool, address asset, uint256 amount) external view returns (Quote memory);

    // admin
    function setQuoteAsset(address asset, bool approved) external;
    function setFeeBps(address token, uint16 feeBps) external;
    function setAnchorBand(address pool, uint16 bandBps) external;
    function resetAnchor(address pool, address asset) external;
    function setPriceOracle(address oracle) external;
    function pause() external;
    function unpause() external;
    function pausePool(address pool, bool paused) external;
    function setFrozen(address account, bool isFrozen) external;
    function setFreezeEnabled(bool enabled) external;
    function upgradePoolImplementation(address newImplementation) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    // errors the hook path can surface
    error UnknownPool();
    error QuoteAssetNotApproved();
    error AccountFrozen();
    error FillShortfall();
}

interface IFlowstatePoolTest {
    function inventoryToken() external view returns (address);
    function factory() external view returns (address);
    function tokenBalance() external view returns (uint256);
    function anchorBandBps() external view returns (uint16);
    function poolPaused() external view returns (bool);
    function claimableQuote(address asset, address user) external view returns (uint256);
    function claimQuote() external;
    function anchorOf(address asset) external view returns (uint192 rate, uint64 time, uint192 ema, uint32 epoch);
    function previewBuy(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 cost);
    function positions(address user)
        external
        view
        returns (uint256 tokenPosition, uint256 cashPosition, uint256 claimT);

    // errors the hook path can surface
    error NoLiquidity();
    error InvalidAmount();
    error AmountTooSmall();
    error RateOutOfBand();
    error PoolIsPaused();
    error FillShortfall();
}

interface ITestSpotOracle {
    function setRate(address src, address dst, uint256 rate) external;
    function setFailing(bool value) external;
    function getRate(address src, address dst, bool useWrappers) external view returns (uint256);
}

/// @notice Deploys the REAL Flowstate pass-1 stack inside a fork, mirroring
///         `PoolParty_Contracts/deploy/flowstate-testnet.js` step for step.
///
/// @dev Order is load-bearing and matches the script: timelocks -> pool impl -> beacon
///      -> proxy template -> fee receiver -> market (UUPS proxy, EIGHT initialize args
///      after PR #9's `emergencyTimelock12`) -> beacon ownership to the MARKET PROXY.
///      Beacon ownership is the one wiring step that is silently wrong if you copy the
///      "give everything to a timelock" instinct: pool clones latch their beacon at
///      initialize, so `FlowstateMarket.upgradePoolImplementation` is the only call that
///      reaches live pools, and it calls `UpgradeableBeacon.upgradeTo` as the beacon's
///      OWNER. `test_Governance_*` in RealStackWiring.t.sol asserts both halves.
abstract contract RealStackDeployer is Test {
    struct RealStack {
        IFlowstateMarketTest market;
        address marketImpl;
        address poolImpl;
        UpgradeableBeacon beacon;
        address template;
        address receiver;
        TimelockController tl48;
        TimelockController tl24;
        TimelockController tl12;
        address oracle;
    }

    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant EMERGENCY_UPGRADER_ROLE = keccak256("EMERGENCY_UPGRADER_ROLE");
    bytes32 internal constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");
    bytes32 internal constant FREEZE_ADMIN_ROLE = keccak256("FREEZE_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @param admin  DEFAULT_ADMIN_ROLE + PAUSER_ROLE holder (the multisig in production).
    /// @param oracle_ price oracle the market is wired to. Pass a `TestSpotOracle` for a
    ///        controllable rate, or RH's live aggregator for the true end-to-end read.
    function _deployRealFlowstateStack(address admin, address keeper, address oracle_)
        internal
        returns (RealStack memory s)
    {
        address[] memory single = new address[](1);
        single[0] = admin;
        s.tl48 = new TimelockController(48 hours, single, single, address(0));
        s.tl24 = new TimelockController(24 hours, single, single, address(0));
        s.tl12 = new TimelockController(12 hours, single, single, address(0));

        s.poolImpl = deployCode("FlowstatePool.sol:FlowstatePool");
        s.beacon = new UpgradeableBeacon(s.poolImpl, address(this));
        s.template = deployCode("InitializableBeaconProxy.sol:InitializableBeaconProxy");

        // spoke-chain receiver, exactly as the deploy script picks for FS_HOME_CHAIN != 1
        s.receiver = deployCode(
            "FlowBridgeCollector.sol:FlowBridgeCollector", abi.encode(admin, keeper, uint256(0), uint256(0))
        );

        s.oracle = oracle_;
        s.marketImpl = deployCode("FlowstateMarket.sol:FlowstateMarket");
        s.market = IFlowstateMarketTest(
            address(
                new ERC1967Proxy(
                    s.marketImpl,
                    abi.encodeCall(
                        IFlowstateMarketTest.initialize,
                        (
                            address(s.beacon),
                            s.template,
                            oracle_,
                            s.receiver,
                            admin,
                            address(s.tl48),
                            address(s.tl24),
                            address(s.tl12)
                        )
                    )
                )
            )
        );

        // pool-logic upgrades run through the market's two-lane role gate
        s.beacon.transferOwnership(address(s.market));

        // the deploy script's sanity probes, kept verbatim so a wiring regression fails
        // here rather than three tests later
        require(s.market.poolBeacon() == address(s.beacon), "beacon wiring mismatch");
        require(s.beacon.owner() == address(s.market), "beacon not market-owned");
        require(s.beacon.implementation() == s.poolImpl, "beacon impl mismatch");
    }

    function _deployTestOracle() internal returns (ITestSpotOracle) {
        return ITestSpotOracle(deployCode("TestSpotOracle.sol:TestSpotOracle"));
    }
}
