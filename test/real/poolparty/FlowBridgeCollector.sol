// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./FlowAccumulatorBase.sol";

/**
 * @title FlowBridgeCollector
 * @notice Spoke-chain accumulator: fees accrue locally; a keeper periodically swaps
 *         them to the bridge asset and bridges home to FlowBuyback. Destination is
 *         CONFIG — the home-chain decision (Base / ETH / Robinhood) binds later with
 *         no rework (scope §6 hard constraint). Spec: plan §3.4 / fee doc §5.
 *
 * @dev Legacy-L2 anti-patterns, each enforced ON-CHAIN here rather than left to
 *      keeper discipline (M4 consistency-by-construction):
 *      - bridge fee reserved BEFORE swapping (require, not care);
 *      - refund address is a mandatory EOA (never address(this) — re-entry deadlock);
 *      - owner + rescue exist (no permanent stranding);
 *      - no swapping in receive() (hot path empty in the base).
 */
contract FlowBridgeCollector is FlowAccumulatorBase {
    using SafeERC20 for IERC20;

    error DestinationNotSet();
    error BridgeAdapterNotSet();
    error BridgeAssetNotSet();
    error RefundNotEOA();
    error InsufficientBridgeFee();

    address public bridgeAsset;   // asset bridged home (e.g. USDC)
    address public bridgeAdapter; // IBridgeAdapter (Stargate/LZ adapter, owner-vetted)
    address public destination;   // home-chain FlowBuyback (allowlisted there)
    uint32 public dstEid;
    address public refundEOA;

    event DestinationSet(address destination, uint32 dstEid);
    event BridgeAdapterSet(address adapter);
    event BridgeAssetSet(address asset);
    event RefundEOASet(address refund);
    event SwappedAndBridged(
        address indexed assetIn, uint256 amountIn, address bridgeAsset, uint256 bridgedAmount, uint32 dstEid
    );

    constructor(address owner_, address keeper_, uint256 minSwapThreshold_, uint256 maxSwapPerTx_)
        FlowAccumulatorBase(owner_, keeper_, minSwapThreshold_, maxSwapPerTx_)
    {}

    // ── owner config ─────────────────────────────────────────────────────

    function setDestination(address destination_, uint32 dstEid_) external onlyOwner {
        if (destination_ == address(0)) revert ZeroAddress();
        destination = destination_;
        dstEid = dstEid_;
        emit DestinationSet(destination_, dstEid_);
    }

    function setBridgeAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        bridgeAdapter = adapter;
        emit BridgeAdapterSet(adapter);
    }

    function setBridgeAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        bridgeAsset = asset;
        emit BridgeAssetSet(asset);
    }

    /// @dev EOA-only, enforced on-chain: a contract refund address is the legacy
    ///      re-entry/deadlock bug; address(this) is the worst case of it.
    function setRefundEOA(address refund) external onlyOwner {
        if (refund == address(0) || refund.code.length != 0) revert RefundNotEOA();
        refundEOA = refund;
        emit RefundEOASet(refund);
    }

    // ── cold path ────────────────────────────────────────────────────────

    /// @notice Keeper-gated: swap an accumulated asset to the bridge asset and bridge
    ///         it home. The bridge's native fee is RESERVED before any swap happens —
    ///         if this contract can't pay the message fee, nothing moves.
    /// @param minBridgeOut keeper-supplied off-chain quote floor for the swap leg
    ///        (ignored when assetIn == bridgeAsset — no swap occurs).
    function swapAndBridge(address assetIn, uint256 amountIn, uint256 minBridgeOut)
        external
        payable
        onlyKeeper
    {
        if (destination == address(0)) revert DestinationNotSet();
        address adapter = bridgeAdapter;
        if (adapter == address(0)) revert BridgeAdapterNotSet();
        address asset = bridgeAsset;
        if (asset == address(0)) revert BridgeAssetNotSet();
        if (refundEOA == address(0)) revert RefundNotEOA();
        _checkAmount(amountIn);

        // reserve the bridge fee BEFORE swapping: native about to be swapped (when
        // assetIn is native) cannot double-count as fee funding
        uint256 fee = IBridgeAdapter(adapter).quoteBridgeFee(asset, destination, dstEid);
        uint256 reservedForSwap = assetIn == address(0) ? amountIn : 0;
        if (address(this).balance < fee + reservedForSwap) revert InsufficientBridgeFee();

        uint256 out =
            assetIn == asset ? amountIn : _swapViaAdapter(assetIn, amountIn, asset, minBridgeOut);

        IERC20(asset).forceApprove(adapter, out);
        IBridgeAdapter(adapter).bridge{value: fee}(asset, out, destination, dstEid, refundEOA);
        IERC20(asset).forceApprove(adapter, 0);

        emit SwappedAndBridged(assetIn, amountIn, asset, out, dstEid);
    }
}
