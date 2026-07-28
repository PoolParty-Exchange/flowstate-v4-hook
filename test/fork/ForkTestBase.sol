// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockFlowstateMarket} from "../mocks/MockFlowstateMarket.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";

/// @notice Base for all RH-mainnet-fork tests: forks the chain, mines the 0x28cc hook
///         address via HookMiner + CREATE2 (the test contract is the deployer), wires
///         the mock market, initializes the test pool against the REAL PoolManager,
///         and funds a swapper with real USDG via deal().
abstract contract ForkTestBase is Test {
    // -- Robinhood Chain (4663) canonical addresses, verified 2026-07-28 ------
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant AEWETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18 decimals

    // -- Arbitrum Orbit fixture: ArbSys precompile mock (returns block.number) --
    // The V4Quoter path does NOT need this (verified 2026-07-28); kept for any
    // future test touching ArbSys-reading contracts.
    address constant ARBSYS = 0x0000000000000000000000000000000000000064;
    bytes constant ARBSYS_MOCK_CODE = hex"4360005260206000f3";

    // -- Hook flags: 0x28cc ---------------------------------------------------
    uint160 constant HOOK_FLAGS = uint160(
        (1 << 13) // BEFORE_INITIALIZE
            | (1 << 11) // BEFORE_ADD_LIQUIDITY
            | (1 << 7) // BEFORE_SWAP
            | (1 << 6) // AFTER_SWAP
            | (1 << 3) // BEFORE_SWAP_RETURNS_DELTA
            | (1 << 2) // AFTER_SWAP_RETURNS_DELTA
    );

    // -- Mock market rate: 2 FLOWMOCK (18d) per 1 USDG (6d) -------------------
    uint256 constant RATE_NUM = 2e12;
    uint256 constant RATE_DEN = 1;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    IV4Quoter quoter = IV4Quoter(V4_QUOTER);

    FlowstateC1Hook hook;
    MockFlowstateMarket market;
    MockInventoryToken token;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey poolKey;
    bool usdgIsCurrency0;

    address swapper = makeAddr("swapper");

    function setUp() public virtual {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.rpcUrl("robinhood"));
        else vm.createSelectFork(vm.rpcUrl("robinhood"), forkBlock);

        token = new MockInventoryToken();
        market = new MockFlowstateMarket(USDG, address(token), RATE_NUM, RATE_DEN);
        token.mint(address(market), 1_000_000e18);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this))
        );
        hook = new FlowstateC1Hook{salt: salt}(POOL_MANAGER, address(market), address(this));
        assertEq(address(hook), hookAddress, "CREATE2 address mismatch");

        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), address(market));

        usdgIsCurrency0 = USDG < address(token);
        (Currency c0, Currency c1) = usdgIsCurrency0
            ? (Currency.wrap(USDG), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(USDG));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(poolKey, _sqrtPriceForMockRate());

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        deal(USDG, swapper, 1_000_000e6);
        vm.startPrank(swapper);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // -- helpers --------------------------------------------------------------

    function mockArbSys() internal {
        vm.etch(ARBSYS, ARBSYS_MOCK_CODE);
    }

    /// @dev sqrtPriceX96 = sqrt((raw1 << 192) / raw0) for the mock rate
    ///      1 USDG (1e6 raw) = 2 FLOWMOCK (2e18 raw). Cosmetic slot0 seed only;
    ///      the hook overrides all pricing.
    function _sqrtPriceForMockRate() internal view returns (uint160) {
        (uint256 raw0, uint256 raw1) = usdgIsCurrency0 ? (uint256(1e6), uint256(2e18)) : (uint256(2e18), uint256(1e6));
        uint256 ratioX192 = (raw1 << 192) / raw0;
        uint256 sqrtPrice = FixedPointMathLib.sqrt(ratioX192);
        require(sqrtPrice > TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "seed out of range");
        return uint160(sqrtPrice);
    }

    /// @dev BUY = USDG in, FLOWMOCK out. zeroForOne depends on currency ordering.
    function _buyZeroForOne() internal view returns (bool) {
        return usdgIsCurrency0;
    }

    function _swapBuy(int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta) {
        bool zeroForOne = _buyZeroForOne();
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _swapSell(int256 amountSpecified) internal returns (BalanceDelta) {
        bool zeroForOne = !_buyZeroForOne();
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Hook reverts bubble up wrapped (PoolManager Wrap__FailedHookCall, quoter
    ///      UnexpectedRevertBytes); asserting on the embedded selector is the robust
    ///      cross-wrapper check.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i <= data.length - 4; i++) {
            if (data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                && data[i + 3] == selector[3]) {
                return true;
            }
        }
        return false;
    }
}
