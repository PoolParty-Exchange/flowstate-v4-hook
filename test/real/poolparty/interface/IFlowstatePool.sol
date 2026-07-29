// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "../libraries/FlowstateStructs.sol";

/**
 * @title IFlowstatePool
 * @notice Beacon-implementation pool interface (pass-1 buy-path surface; sell/buy-back
 *         entrypoints land in M2 per the implementation plan §7).
 */
interface IFlowstatePool {
    function initialize(
        address token,
        address quoteAsset_,
        address factory_,
        uint16 bandBps,
        uint192 seedRate,
        uint32 seedEpoch
    ) external;

    // ── liquidity (factory has already moved assets in; balance-diff measured) ──
    function creditTokenContribution(address owner, uint256 actualAmount) external;
    function creditQuoteContribution(address owner, uint256 actualAmount) external;
    function withdrawTokensFor(address owner, uint256 amount)
        external
        returns (uint256 withdrawn, bool nowEmpty);
    function withdrawQuoteFor(address owner, uint256 amount)
        external
        returns (uint256 withdrawn, bool cashSideEmpty);

    // ── trading ──────────────────────────────────────────────────────────
    function priceBuy(uint256 requestedAmount, address oracle, uint32 epoch)
        external
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate);

    function priceBuyExactQuote(uint256 quoteIn, address oracle, uint32 epoch)
        external
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate);

    function settleBuy(
        address buyer,
        uint256 fillAmount,
        uint256 quotePaid,
        uint256 rate,
        FlowstateStructs.FeeContext calldata ctx
    ) external;

    function priceSell(uint256 requestedAmount, address oracle, uint32 epoch)
        external
        returns (uint256 fillableAmount, uint256 quoteGross, uint256 rate);

    function settleSell(
        address seller,
        uint256 fillAmount,
        uint256 quoteGross,
        uint256 rate,
        FlowstateStructs.FeeContext calldata ctx
    ) external returns (uint256 sellerNet);

    // ── claims ───────────────────────────────────────────────────────────
    function claimQuote() external;
    function claimQuoteFor(address user) external;
    function claimTokens() external;
    function claimTokensFor(address user) external;
    function setRecycleOptIn(bool optIn) external;

    // ── config (factory-only) ────────────────────────────────────────────
    function setAnchorBand(uint16 bandBps) external;
    function setPaused(bool paused) external;
    function resetAnchor(address oracle, uint32 epoch) external;
    function setBuyBack(bool enabled, uint16 spreadBps, uint128 maxPerWindow, uint32 windowSecs) external;
    function setPriceSource(uint8 source) external;

    // ── views ────────────────────────────────────────────────────────────
    function previewBuy(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 cost);
    function previewSell(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 grossProceeds);
    function inventoryToken() external view returns (address);
    function quoteAsset() external view returns (address);
    function tokenBalance() external view returns (uint256);
    function anchor() external view returns (uint192 rate, uint64 time, uint32 epoch);
    function positions(address user)
        external
        view
        returns (uint256 tokenPosition, uint256 cashPosition, uint256 claimQ, uint256 claimT);
    function getPlaceInLine(address user, bool cashSide) external view returns (uint256);
}
