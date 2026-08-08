// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The one market entry point the seeder consumes: deposit on behalf of a named
///      contribution owner (FlowstateMarket "gift semantics", R10). Tokens are pulled
///      from msg.sender (this contract); the position is credited to contributionOwner.
interface IFlowstateMarketDeposit {
    function contributeTokens(address pool, uint256 amount, address contributionOwner) external;
}

/// @dev The one hook surface the seeder reads: whether a pool's beacon is already lit.
interface IBeaconHook {
    function beaconSeeded(PoolId poolId) external view returns (bool);
}

/// @title FlowstateBeaconSeeder
/// @notice UNPRIVILEGED convenience periphery for the GMGN-visibility beacon (JUP-516).
///         The hook itself enforces the only invariant that matters (at most one
///         liquidityDelta == 1 add per pool, from anyone); this contract merely makes
///         firing it convenient and bundles it with a first deposit so a depositor
///         needs ONE approval and ONE transaction.
///
///         Funding rule (no-protocol-capital, Hamish 2026-07-28): the caller pays the
///         dust and the gas. The dust's unit count is price-dependent (fork-measured:
///         1 wei at the live CASHCAT price; ~4.2k wei of an 18d token at the test
///         fixture's price — roughly the value of 1 wei of the counter-asset, always
///         value-negligible). Flowstate never funds or holds anything here; between
///         transactions this contract's balances are zero and the position it
///         custodies is 1 unit of liquidity, permanently locked (no remove path, by
///         design).
contract FlowstateBeaconSeeder is IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IFlowstateMarketDeposit public immutable market;

    error NotPoolManager();
    error NotPayer();
    error ZeroAddress();
    error PayCurrencyNotInPool();
    error NativePayUnsupported();

    /// @notice The beacon mint inside seedAndDeposit failed; the deposit proceeded.
    ///         The pool stays unlit until anyone calls seed() successfully.
    event BeaconSeedSkipped(PoolId indexed poolId, bytes reason);

    constructor(address _poolManager, address _market) {
        if (_poolManager == address(0) || _market == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        market = IFlowstateMarketDeposit(_market);
    }

    // -------------------------------------------------------------------------
    // Entry points
    // -------------------------------------------------------------------------

    /// @notice Light a pool's beacon: mint the single permitted 1-liquidity dust
    ///         position, paid by the caller in `payToken` (~1 wei, fork-measured).
    ///         Caller must have approved this contract for a few wei of `payToken`.
    /// @param key      the V4 pool key (its hook enforces once-per-pool and delta == 1).
    /// @param payToken the ERC-20 the caller pays the dust in; must be one of the
    ///                 pool's two currencies (for C1 pools, the inventory token —
    ///                 depositors already hold it).
    function seed(PoolKey calldata key, address payToken) external nonReentrant {
        _seed(key, payToken, msg.sender);
    }

    /// @notice First-deposit bundle: light the beacon if unlit (a beacon failure NEVER
    ///         blocks the deposit), then deposit `amount` of the inventory token into
    ///         the C1 pool credited directly to the caller. One approval (this
    ///         contract, amount + 2 wei of the inventory token), one transaction.
    /// @param key            the V4 pool key for this pair.
    /// @param marketPool     the C1 pool receiving the deposit.
    /// @param inventoryToken the pool's inventory token (mismatches revert inside the
    ///                       market's pull; nothing can be lost to a wrong value).
    /// @param amount         inventory-token amount to deposit.
    function seedAndDeposit(PoolKey calldata key, address marketPool, address inventoryToken, uint256 amount)
        external
        nonReentrant
    {
        if (!IBeaconHook(address(key.hooks)).beaconSeeded(key.toId())) {
            try this.seedFor(key, inventoryToken, msg.sender) {}
            catch (bytes memory reason) {
                emit BeaconSeedSkipped(key.toId(), reason);
            }
        }
        IERC20(inventoryToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(inventoryToken).forceApprove(address(market), amount);
        market.contributeTokens(marketPool, amount, msg.sender);
    }

    /// @notice try/catch shim for seedAndDeposit. Callable externally only in the ways
    ///         that spend the payer's own tokens: by this contract itself, or by the
    ///         payer directly.
    function seedFor(PoolKey calldata key, address payToken, address payer) external {
        if (msg.sender != address(this) && msg.sender != payer) revert NotPayer();
        _seed(key, payToken, payer);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _seed(PoolKey calldata key, address payToken, address payer) internal {
        if (Currency.unwrap(key.currency0) != payToken && Currency.unwrap(key.currency1) != payToken) {
            revert PayCurrencyNotInPool();
        }
        if (payToken == address(0)) revert NativePayUnsupported();
        poolManager.unlock(abi.encode(key, payToken, payer));
    }

    /// @dev Mints liquidityDelta == 1 in a one-spacing range placed entirely on the
    ///      side of the current tick that owes ONLY `payToken`, then settles the owed
    ///      wei straight from the payer to the PoolManager. The position belongs to
    ///      this contract (salt 0) and there is deliberately no remove path.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address payToken, address payer) = abi.decode(data, (PoolKey, address, address));

        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        bool payIsCurrency0 = Currency.unwrap(key.currency0) == payToken;
        int24 spacing = key.tickSpacing;
        int24 lower;
        int24 upper;
        if (payIsCurrency0) {
            // range fully ABOVE the current tick owes only currency0
            lower = ((tick / spacing) + 1) * spacing;
            upper = lower + spacing;
        } else {
            // range fully BELOW the current tick owes only currency1
            upper = ((tick / spacing) - 1) * spacing;
            lower = upper - spacing;
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: 0}), ""
        );

        _settleOwed(key.currency0, delta.amount0(), payer);
        _settleOwed(key.currency1, delta.amount1(), payer);
        return "";
    }

    function _settleOwed(Currency currency, int128 amount, address payer) internal {
        if (amount >= 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), uint256(uint128(-amount)));
        poolManager.settle();
    }
}
