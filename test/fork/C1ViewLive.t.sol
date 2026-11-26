// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {FlowstateC1View} from "../../src/lens/FlowstateC1View.sol";

struct AnchorFloor {
    address asset;
    uint192 minRate;
}

struct PermitDetails {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

struct PermitSingle {
    PermitDetails details;
    address spender;
    uint256 sigDeadline;
}

interface IListingRegistryLive {
    function list(
        address token,
        uint256 amount,
        uint64 expiry,
        bytes32 supplierCode,
        AnchorFloor[] calldata floors,
        PermitSingle calldata permit,
        bytes calldata permitSig
    ) external returns (uint64 id);
    function cancel(uint64 id) external;
}

interface IListingPoolLive {
    function seededAssets() external view returns (address[] memory);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IMarketLive {
    function poolByToken(address token) external view returns (address);
}

/// @dev Pays for an exact-input buy the way a router does (v4-periphery SETTLE / TAKE), so the
///      test can compare the view's answer with a real fill at the same block.
contract TestBuyRouter is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function buy(PoolKey memory key, bool zeroForOne, uint256 amountIn) external payable returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    /// @dev The same buy with exactly `unlockGas` handed to PoolManager.unlock, the figure the
    ///      view's simGas stands for.
    function buyWithGas(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 unlockGas)
        external
        payable
        returns (uint256 out)
    {
        out = abi.decode(pm.unlock{gas: unlockGas}(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool zf, uint256 amountIn, address payer) = abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({zeroForOne: zf, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: zf ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        (Currency cin, Currency cout) = zf ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 inD = zf ? d.amount0() : d.amount1();
        int128 outD = zf ? d.amount1() : d.amount0();
        uint256 owe = uint256(uint128(-inD));
        if (cin.isAddressZero()) {
            pm.settle{value: owe}();
        } else {
            pm.sync(cin);
            IERC20(Currency.unwrap(cin)).transferFrom(payer, address(pm), owe);
            pm.settle();
        }
        uint256 got = uint256(uint128(outD));
        pm.take(cout, payer, got);
        return abi.encode(got);
    }

    receive() external payable {}
}

/// @notice The view against the LIVE hook, market, settlement and registry on a fork of chain 4663.
///         Stock is created the way a seller creates it: the seller wallet behind listings 6 and 7
///         cancels the dead listing 7 and lists again. Then every figure the view gives is checked
///         against a real buy at the same block.
contract C1ViewLiveForkTest is Test {
    // the live FlowState r2 hook (verified in .claude/identities.json)
    FlowstateC1Hook constant HOOK = FlowstateC1Hook(payable(0x39D37b42c2575CbC65A88440A5020aA18fefa8cC));
    // the routing form's token and the launchpad reference token (symbol() reads, 26 Nov)
    address constant FORM_TOKEN = 0x45242320DBB855EeA8Fd36804C6487E10E97FCF9;
    address constant REF_TOKEN = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant QUOTE_USD = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // the seller wallet of listings 6 and 7 (deployment-ledger/first_routed_fill_2026-11-18)
    address constant SELLER = 0x1e4B26315fb7B3Ab8720e1272F093D64e409D3C9;

    uint256 constant SIM_GAS = 1_200_000;
    uint256 constant AMPLE_GAS = 30_000_000;

    FlowstateC1View view_;
    TestBuyRouter router;
    IPoolManager pm;
    PoolKey formKey;
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envOr("RH_RPC", string("https://rpc.mainnet.chain.robinhood.com")));
        // The chain's block-number system contract (ArbSys at 0x64) does not exist in a Foundry
        // fork; this stand-in returns the block number, as the earlier fork runs did
        // (deployment-ledger/tycho_fork_test_2026-11-18/tycho_fork_test.cjs:75).
        vm.etch(address(0x64), hex"4360005260206000f3");
        view_ = new FlowstateC1View(HOOK);
        pm = HOOK.poolManager();
        router = new TestBuyRouter(pm);
        formKey = _key(address(0), FORM_TOKEN);
        vm.deal(buyer, 1_000 ether);
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 0, tickSpacing: 60, hooks: IHooks(address(HOOK))});
    }

    /// @dev Cancel the dead listing 7 and list `amount` from the same seller (live registry rules).
    function _relist(uint256 amount) internal returns (uint64 id) {
        IListingRegistryLive reg = IListingRegistryLive(address(HOOK.listingRegistry()));
        address pool = IMarketLive(address(HOOK.market())).poolByToken(FORM_TOKEN);
        address[] memory seeded = IListingPoolLive(pool).seededAssets();
        AnchorFloor[] memory floors = new AnchorFloor[](seeded.length);
        for (uint256 i; i < seeded.length; i++) floors[i] = AnchorFloor(seeded[i], 1);
        uint256 bal = IERC20(FORM_TOKEN).balanceOf(SELLER);
        if (bal < amount) deal(FORM_TOKEN, SELLER, amount);
        PermitSingle memory none;
        vm.startPrank(SELLER);
        reg.cancel(7);
        id = reg.list(FORM_TOKEN, amount, uint64(block.timestamp + 1 days), bytes32(0), floors, none, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------ live state, no stock

    function test_LiveState_NoStock_ReasonsAndSharedPool() public {
        FlowstateC1View.PoolAnswer memory f = view_.answer(formKey, SIM_GAS);
        assertFalse(f.active, "form pool inactive");
        assertEq(f.reason, 5, "form pool: STOP_STOCK");
        assertEq(f.available, 0);
        assertEq(f.quoteCurrency, address(0), "native ETH quote");

        FlowstateC1View.PoolAnswer memory r1 = view_.answer(_key(address(0), REF_TOKEN), SIM_GAS);
        FlowstateC1View.PoolAnswer memory r2 = view_.answer(_key(QUOTE_USD, REF_TOKEN), SIM_GAS);
        assertEq(r1.reason, 6, "ref ETH pool: STOP_CLOSED");
        assertEq(r2.reason, 6, "ref USD pool: STOP_CLOSED");
        assertEq(r1.marketPool, r2.marketPool, "two keys, one market pool");
        assertTrue(r1.marketPool != address(0));

        FlowstateC1View.PoolAnswer memory missing = view_.answer(_key(QUOTE_USD, FORM_TOKEN), SIM_GAS);
        assertFalse(missing.active);
        assertEq(missing.reason, view_.REASON_OTHER_REVERT(), "uninitialised pool");
    }

    function test_RejectsOtherHook() public {
        PoolKey memory k = formKey;
        k.hooks = IHooks(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1View.WrongHook.selector, address(0xdead)));
        view_.answer(k, SIM_GAS);
    }

    // ------------------------------------------------------------ with a live listing

    function test_WithListing_AvailableMatchesRealBuys() public {
        _relist(20_000e18);
        FlowstateC1View.PoolAnswer memory a = view_.answer(formKey, SIM_GAS);
        emit log_named_uint("available", a.available);
        emit log_named_uint("probeCeiling", a.probeCeiling);
        emit log_named_uint("maxAmountIn", a.maxAmountIn);
        emit log_named_uint("reason", a.reason);
        emit log_named_uint("rate", a.rate);
        emit log_named_uint("gateWhy", a.gateWhy);
        assertTrue(a.active, "active with a listing");
        assertTrue(a.rateOk, "rate read");
        assertEq(a.gateWhy, 0, "settlement gates open");
        assertEq(a.marketAsset, address(HOOK.weth9()), "native pair: the market is called with the wrapped asset");
        assertGt(a.available, 0);
        assertLe(a.available, a.probeCeiling, "confirmed never above the probe");
        assertLe(a.probeCeiling, 20_000e18, "never more than listed");

        // a real buy at maxAmountIn, with exactly simGas handed to unlock, fills exactly `available`
        vm.prank(buyer);
        uint256 got = router.buyWithGas{value: a.maxAmountIn}(formKey, true, a.maxAmountIn, SIM_GAS);
        assertEq(got, a.available, "real fill at maxAmountIn equals available");
    }

    /// @dev For each gas level: whenever the view says a buy fills, the same buy through a router
    ///      whose unlock gets that same gas fills the same amount. Run with --isolate for cold state.
    function test_GasCalibration_ActiveMeansRealFill() public {
        _relist(9_000e18);
        _listFrom(makeAddr("seller2"), 12_000e18);
        uint256[5] memory levels = [uint256(900_000), 1_100_000, 1_400_000, 1_800_000, 2_400_000];
        for (uint256 i; i < levels.length; i++) {
            uint256 snap = vm.snapshotState();
            FlowstateC1View.PoolAnswer memory a = view_.answer(formKey, levels[i]);
            emit log_named_uint("simGas", levels[i]);
            emit log_named_uint("  available", a.available);
            emit log_named_uint("  reason", a.reason);
            if (a.active) {
                vm.prank(buyer);
                uint256 got = router.buyWithGas{value: a.maxAmountIn}(formKey, true, a.maxAmountIn, levels[i]);
                assertEq(got, a.available, "active means a real fill of that size at that gas");
            }
            vm.revertToState(snap);
        }
    }

    function test_WithListing_QuoteLadderMatchesRealBuys() public {
        _relist(20_000e18);
        uint256[] memory sizes = new uint256[](3);
        sizes[0] = 0.0005 ether;
        sizes[1] = 0.005 ether;
        sizes[2] = 0.02 ether;
        (uint256[] memory outs, uint8[] memory reasons,) = view_.quote(formKey, sizes, SIM_GAS);
        for (uint256 i; i < sizes.length; i++) {
            emit log_named_uint("size", sizes[i]);
            emit log_named_uint("out", outs[i]);
            if (reasons[i] != 0) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(buyer);
            uint256 got = router.buy{value: sizes[i]}(formKey, true, sizes[i]);
            assertEq(got, outs[i], "real fill equals quote");
            vm.revertToState(snap);
        }
    }

    function test_WithListing_LessGasNeverReportsMore() public {
        _relist(20_000e18);
        FlowstateC1View.PoolAnswer memory full = view_.answer(formKey, AMPLE_GAS);
        FlowstateC1View.PoolAnswer memory tight = view_.answer(formKey, SIM_GAS);
        FlowstateC1View.PoolAnswer memory starved = view_.answer(formKey, 400_000);
        emit log_named_uint("available all gas", full.available);
        emit log_named_uint("available 1.2M", tight.available);
        emit log_named_uint("available 400k", starved.available);
        emit log_named_uint("reason 400k", starved.reason);
        assertLe(tight.available, full.available);
        assertLe(starved.available, tight.available);
    }

    /// @dev A second seller lists behind the first: the view must count both and a buy that crosses
    ///      from one listing into the next must fill what quote() said.
    function test_TwoSellers_CrossingBuyMatches() public {
        _relist(9_000e18);
        address seller2 = makeAddr("seller2");
        _listFrom(seller2, 12_000e18);

        uint256[4] memory gasLevels = [uint256(1_200_000), 2_000_000, 3_000_000, AMPLE_GAS];
        for (uint256 i; i < 4; i++) {
            FlowstateC1View.PoolAnswer memory g = view_.answer(formKey, gasLevels[i]);
            emit log_named_uint("simGas", gasLevels[i]);
            emit log_named_uint("  available", g.available);
            emit log_named_uint("  reason", g.reason);
        }
        FlowstateC1View.PoolAnswer memory a = view_.answer(formKey, AMPLE_GAS);
        assertEq(a.probeCeiling, 21_000e18, "both listings reached with enough gas");
        assertGe(a.available, 21_000e18 * 99 / 100, "confirmed within 1% of the ceiling");
        FlowstateC1View.PoolAnswer memory tight = view_.answer(formKey, SIM_GAS);
        assertLe(tight.available, a.available, "less gas never reports more");

        // a buy sized past the first listing, simulated and executed with the same ample gas
        uint256 size = 0.015 ether;
        (uint256[] memory outs, uint8[] memory reasons,) = view_.quote(formKey, _one(size), AMPLE_GAS);
        assertEq(reasons[0], 0);
        assertGt(outs[0], 9_000e18, "crosses into the second listing");
        vm.prank(buyer);
        uint256 got = router.buy{value: size}(formKey, true, size);
        assertEq(got, outs[0], "crossing fill equals quote");

        FlowstateC1View.PoolAnswer memory after_ = view_.answer(formKey, AMPLE_GAS);
        assertEq(after_.probeCeiling, 21_000e18 - got, "the ceiling falls by what was sold");
    }

    function _listFrom(address seller, uint256 amount) internal {
        IListingRegistryLive reg = IListingRegistryLive(address(HOOK.listingRegistry()));
        address pool = IMarketLive(address(HOOK.market())).poolByToken(FORM_TOKEN);
        address[] memory seeded = IListingPoolLive(pool).seededAssets();
        AnchorFloor[] memory floors = new AnchorFloor[](seeded.length);
        for (uint256 i; i < seeded.length; i++) floors[i] = AnchorFloor(seeded[i], 1);
        deal(FORM_TOKEN, seller, amount);
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        PermitSingle memory none;
        vm.startPrank(seller);
        IERC20(FORM_TOKEN).approve(permit2, type(uint256).max);
        IPermit2Approve(permit2).approve(FORM_TOKEN, address(HOOK.listingSettlement()), type(uint160).max, uint48(block.timestamp + 30 days));
        reg.list(FORM_TOKEN, amount, uint64(block.timestamp + 1 days), bytes32(0), floors, none, "");
        vm.stopPrank();
    }

    function test_SpreadPassthroughMatchesHook() public view {
        uint256 s = view_.spreadBpsFor(formKey, 0.01 ether);
        assertEq(s, HOOK.spreadBpsFor(Currency.wrap(address(0)), Currency.wrap(FORM_TOKEN), 0.01 ether));
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }
}
