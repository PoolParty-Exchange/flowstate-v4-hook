// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/IFlowAdapters.sol";

/**
 * @title FlowAccumulatorBase
 * @notice Shared skeleton of FlowBuyback (home chain) and FlowBridgeCollector (spokes):
 *         hot path = empty receive() + plain ERC20 arrivals (no hooks, no SSTOREs,
 *         cannot revert — buyers never pay for buybacks); cold path = keeper-gated,
 *         owner-configured, on-chain-verified.
 *
 * @dev Consistency-by-construction (M4 principle): every structural assumption a
 *      keeper relies on is enforced here — amount gates, route wiring, output measured
 *      by balance-diff (never adapter-claimed) — with ONE deliberate exception:
 *      `minOut` is keeper-supplied from an off-chain quote and never derived on-chain
 *      (a same-tx on-chain quote is the sandwichable anti-pattern; fee doc §5).
 *
 *      The 7-day two-step rescue IS the designed stranded-value fallback (plan R8):
 *      if FLOW / the home chain is indefinitely deferred, the owner multisig sweeps
 *      accumulated value to treasury through it. Non-upgradeable by design — small,
 *      replaceable by config repoint at the factory.
 */
abstract contract FlowAccumulatorBase is Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyKeeper();
    error ZeroAddress();
    error AmountBelowThreshold();
    error AmountAboveMax();
    error RouteNotSet();
    error InsufficientOutput();
    error RescueNotInitiated();
    error RescueNotReady();
    /// @dev The execution window after maturity has passed; the notice went
    ///      stale and a fresh initiateRescue must run the full course.
    error RescueExpired();
    /// @dev Arming with a zero balance would serve a notice with nothing at
    ///      risk, which is the arm-early-sweep-later pattern this lane must
    ///      not permit (JUP-545).
    error NothingToRescue();
    error NativeTransferFailed();

    uint256 public constant RESCUE_DELAY = 7 days;
    /// @notice How long a matured rescue stays executable. The 7-day delay is
    ///         a NOTICE, and a notice is only meaningful if it cannot be
    ///         parked: without an expiry, an armed rescue could sit matured
    ///         indefinitely and fire the moment it becomes worth firing.
    uint256 public constant RESCUE_WINDOW = 7 days;
    /// @dev assetIn key address(0) = native.
    mapping(address assetIn => address adapter) public swapAdapters;
    mapping(address asset => uint256 unlockAt) public rescueUnlockAt;
    /// @notice Amount snapshotted when the rescue was armed. Execution sends at
    ///         most this: value arriving AFTER the notice was served has had no
    ///         notice served on it and needs a fresh 7-day cycle (JUP-545).
    mapping(address asset => uint256 armed) public rescueAmount;
    address public keeper;
    uint256 public minSwapThreshold;
    uint256 public maxSwapPerTx; // 0 = uncapped

    event KeeperSet(address keeper);
    event ThresholdSet(uint256 minSwapThreshold);
    event MaxSwapSet(uint256 maxSwapPerTx);
    event SwapAdapterSet(address indexed assetIn, address adapter);
    event RescueInitiated(address indexed asset, uint256 unlockAt, uint256 amount);
    event RescueCancelled(address indexed asset);
    event RescueExecuted(address indexed asset, address to, uint256 amount);

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    constructor(address owner_, address keeper_, uint256 minSwapThreshold_, uint256 maxSwapPerTx_)
        Ownable(owner_)
    {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        minSwapThreshold = minSwapThreshold_;
        maxSwapPerTx = maxSwapPerTx_;
    }

    /// @notice HOT PATH — must stay empty forever (no SSTORE, no logic, cannot revert).
    receive() external payable {}

    // ── owner config ─────────────────────────────────────────────────────

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setThreshold(uint256 value) external onlyOwner {
        minSwapThreshold = value;
        emit ThresholdSet(value);
    }

    function setMaxSwapPerTx(uint256 value) external onlyOwner {
        maxSwapPerTx = value;
        emit MaxSwapSet(value);
    }

    function setSwapAdapter(address assetIn, address adapter) external onlyOwner {
        swapAdapters[assetIn] = adapter; // address(0) clears the route
        emit SwapAdapterSet(assetIn, adapter);
    }

    // ── rescue (two-step, timelocked in-contract — plan R8) ─────────────

    function initiateRescue(address asset) external onlyOwner {
        uint256 amount = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue();
        uint256 unlockAt = block.timestamp + RESCUE_DELAY;
        rescueUnlockAt[asset] = unlockAt;
        rescueAmount[asset] = amount;
        emit RescueInitiated(asset, unlockAt, amount);
    }

    function cancelRescue(address asset) external onlyOwner {
        delete rescueUnlockAt[asset];
        delete rescueAmount[asset];
        emit RescueCancelled(asset);
    }

    /// @notice Sweeps the ARMED amount of `asset` (address(0) = native) to `to`:
    ///         the amount snapshotted when the notice was served, or the current
    ///         balance if it has since dropped below that. Value accumulated
    ///         after arming needs a fresh notice; a matured rescue lapses after
    ///         RESCUE_WINDOW. For a wind-down this means periodic arm/execute
    ///         cycles rather than one open-ended sweep, which is the point.
    function executeRescue(address asset, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 unlockAt = rescueUnlockAt[asset];
        if (unlockAt == 0) revert RescueNotInitiated();
        if (block.timestamp < unlockAt) revert RescueNotReady();
        if (block.timestamp > unlockAt + RESCUE_WINDOW) revert RescueExpired();
        uint256 armed = rescueAmount[asset];
        delete rescueUnlockAt[asset];
        delete rescueAmount[asset];

        uint256 amount;
        if (asset == address(0)) {
            amount = address(this).balance;
            if (armed < amount) amount = armed;
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            if (armed < amount) amount = armed;
            IERC20(asset).safeTransfer(to, amount);
        }
        emit RescueExecuted(asset, to, amount);
    }

    // ── shared cold-path internals ───────────────────────────────────────

    function _checkAmount(uint256 amountIn) internal view {
        if (amountIn < minSwapThreshold) revert AmountBelowThreshold();
        if (maxSwapPerTx != 0 && amountIn > maxSwapPerTx) revert AmountAboveMax();
    }

    /// @dev Swap `amountIn` of `assetIn` for `targetAsset` via the owner-vetted
    ///      adapter. Output is measured by OUR balance-diff of targetAsset — the
    ///      adapter's claims are never trusted (consistency-by-construction).
    function _swapViaAdapter(address assetIn, uint256 amountIn, address targetAsset, uint256 minOut)
        internal
        returns (uint256 out)
    {
        address adapter = swapAdapters[assetIn];
        if (adapter == address(0)) revert RouteNotSet();

        uint256 balanceBefore = IERC20(targetAsset).balanceOf(address(this));
        if (assetIn == address(0)) {
            ISwapAdapter(adapter).swapExactInput{value: amountIn}(assetIn, amountIn, targetAsset, address(this));
        } else {
            IERC20(assetIn).forceApprove(adapter, amountIn);
            ISwapAdapter(adapter).swapExactInput(assetIn, amountIn, targetAsset, address(this));
            IERC20(assetIn).forceApprove(adapter, 0);
        }
        out = IERC20(targetAsset).balanceOf(address(this)) - balanceBefore;
        if (out == 0 || out < minOut) revert InsufficientOutput();
    }
}
