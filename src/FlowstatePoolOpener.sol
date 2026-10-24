// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {FlowstateC1Hook} from "./FlowstateC1Hook.sol";
import {IFlowstatePoolOpener} from "./interfaces/IFlowstatePoolOpener.sol";

/// @dev The one C1 pool read the opener makes: the durable anchor of the asset the pool is keyed on,
///      the price the pool's depositors consented to. Zero when the asset is unseeded.
interface IOpenerPoolAnchors {
    function anchorOf(address asset) external view returns (uint192 rate, uint64 blockNumber, uint32 epoch);
}

/// @title FlowstatePoolOpener
/// @notice Gen-6 (JUP-772, Hamish 24 Oct 2026: "the calls should be built into the user actions"). The two
///         Uniswap-side steps that every new token needed an operator for until now, initialising the
///         V4 pool key and lighting the visibility beacon, done by the hook itself inside the user's
///         transaction. They live here, not in the hook, because the hook's runtime is 536 bytes under
///         EIP-170 (24,040 of 24,576 at Gen-5). The hook holds this contract's address as an immutable
///         and is the only caller that can spend anything here; `open` is permissionless because the
///         PoolManager's initialize is, and the hook's beforeInitialize is the gate either way.
///
///         Funding rule (no protocol capital, Hamish 28 Jul 2026): the beacon's dust (about one wei of
///         the quote currency) is paid out of the hook's own spread on the fill that lights it, never
///         from the buyer, never from a pool, never from an operator wallet. Between transactions this
///         contract holds nothing; the one position it owns per pool is 1 unit of liquidity, out of
///         range by construction, with no remove path.
contract FlowstatePoolOpener is IFlowstatePoolOpener {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotHook();
    error UnexpectedNativeSender(address sender);
    error BeaconUnaffordable(uint256 owed, uint256 maxPay);
    error BeaconRangeOutOfBounds(int24 tickLower, int24 tickUpper);
    error UnexpectedOwed(int128 amount0, int128 amount1);

    /// @notice The hook's pools: fee 0, the canonical tick spacing, this hook (FlowstateC1Hook.CANONICAL_TICK_SPACING).
    int24 public constant TICK_SPACING = 60;
    /// @dev An anchor at or above this cannot be turned into a sqrt price without overflow; the pool is
    ///      then opened at 1:1 (a cosmetic price: the hook prices every swap itself).
    uint256 internal constant MAX_SEED_RATE = 1 << 64;
    uint160 internal constant ONE_TO_ONE = 1 << 96;

    IPoolManager public immutable poolManager;
    /// @notice The hook these pools belong to. Deployed before the hook at a CREATE address predicted
    ///         from the deployer's nonce, so the hook's mined CREATE2 address can carry this contract
    ///         and this contract the hook's.
    IHooks public immutable hook;
    IWETH9 public immutable weth9;

    /// @dev Native arrives only from the wrapper's withdraw inside lightBeacon.
    receive() external payable {
        if (msg.sender != address(weth9)) revert UnexpectedNativeSender(msg.sender);
    }

    constructor(address _poolManager, address _hook, address _weth9) {
        if (_poolManager == address(0) || _hook == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        hook = IHooks(_hook);
        weth9 = IWETH9(_weth9);
    }

    /// @notice The V4 pool key of a pair on this hook.
    function keyFor(Currency a, Currency b) public view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: hook});
    }

    /// @inheritdoc IFlowstatePoolOpener
    function open(Currency quote, Currency token) external returns (bool opened) {
        PoolKey memory key = keyFor(quote, token);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 != 0) return true;
        // the pair as the hook holds it: its C1 pool and the asset the market is called with
        (address marketPool, bool quoteIsCurrency0, bool registered,, address marketAsset) =
            FlowstateC1Hook(payable(address(hook))).pairs(keccak256(abi.encode(key.currency0, key.currency1)));
        if (!registered) return false;
        try poolManager.initialize(key, seedPrice(marketPool, marketAsset, quoteIsCurrency0)) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice The slot0 seed for a pool: the C1 pool's durable anchor for `marketAsset` (raw quote
    ///         units per 1e18 token units) as a sqrt price in the key's orientation, 1:1 when the
    ///         anchor is unseeded, unreadable or out of the representable range.
    function seedPrice(address marketPool, address marketAsset, bool quoteIsCurrency0) public view returns (uint160) {
        uint256 rate;
        // a call to an address without code reverts in the caller, outside try/catch: check first
        if (marketPool.code.length != 0) {
            try IOpenerPoolAnchors(marketPool).anchorOf(marketAsset) returns (uint192 r, uint64, uint32) {
                rate = r;
            } catch {}
        }
        if (rate == 0 || rate >= MAX_SEED_RATE) return ONE_TO_ONE;
        // price = raw1 per raw0; sqrtPriceX96 = sqrt(price) * 2^96 = sqrt((raw1 << 192) / raw0)
        (uint256 raw0, uint256 raw1) = quoteIsCurrency0 ? (rate, uint256(1e18)) : (uint256(1e18), rate);
        uint256 sqrtPrice = FixedPointMathLib.sqrt((raw1 << 192) / raw0);
        if (sqrtPrice <= TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) return ONE_TO_ONE;
        return uint160(sqrtPrice);
    }

    /// @inheritdoc IFlowstatePoolOpener
    function lightBeacon(PoolKey calldata key, bool payIsCurrency0, uint256 maxPay) external returns (uint256 paid) {
        if (msg.sender != address(hook)) revert NotHook();
        Currency pay = payIsCurrency0 ? key.currency0 : key.currency1;
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        (int24 lower, int24 upper) = computeBeaconRange(tick, key.tickSpacing, payIsCurrency0);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        // what one unit of liquidity in that range owes, rounded up as the PoolManager rounds it
        paid = payIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, 1, true)
            : SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, 1, true);
        if (paid > maxPay) revert BeaconUnaffordable(paid, maxPay);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: 0}), ""
        );
        int128 owed0 = delta.amount0();
        int128 owed1 = delta.amount1();
        if (payIsCurrency0 ? (owed1 != 0 || owed0 != -int128(uint128(paid))) : (owed0 != 0 || owed1 != -int128(uint128(paid)))) {
            revert UnexpectedOwed(owed0, owed1);
        }

        if (pay.isAddressZero()) {
            // the hook holds a native quote's spread as the wrapper: take exactly what is owed, unwrap, settle
            IERC20(address(weth9)).safeTransferFrom(address(hook), address(this), paid);
            weth9.withdraw(paid);
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(pay);
            IERC20(Currency.unwrap(pay)).safeTransferFrom(address(hook), address(poolManager), paid);
            poolManager.settle();
        }
    }

    /// @notice The beacon position's range: one tickSpacing wide, entirely on the side of `tick` that
    ///         owes only the payer's currency (above the current tick owes currency0; below owes
    ///         currency1). The same placement as FlowstateBeaconSeeder.computeBeaconRange.
    function computeBeaconRange(int24 tick, int24 spacing, bool payIsCurrency0)
        public
        pure
        returns (int24 lower, int24 upper)
    {
        if (payIsCurrency0) {
            lower = ((tick / spacing) + 1) * spacing;
            upper = lower + spacing;
        } else {
            upper = ((tick / spacing) - 1) * spacing;
            lower = upper - spacing;
        }
        if (lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert BeaconRangeOutOfBounds(lower, upper);
    }
}
