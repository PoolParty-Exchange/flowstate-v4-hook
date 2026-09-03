// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "../libraries/FlowstateStructs.sol";

/**
 * @title IFlowstatePool
 * @notice Beacon-implementation pool interface (multi-asset: one pool per inventory
 *         token; the quote asset is a per-trade parameter on every buy path. The
 *         cash side / buy-back runs in ONE designated asset per pool).
 */
interface IFlowstatePool {
    function initialize(address token, address factory_, uint16 bandBps) external;

    // ── anchors (factory-only writes; seeding is band-check-free by definition) ─
    function seedAnchor(address asset, uint192 seedRate, uint32 seedEpoch) external;
    function resetAnchor(address asset, address oracle, uint32 epoch) external;

    // ── liquidity (factory has already moved assets in; balance-diff measured) ──
    function creditTokenContribution(address owner, uint256 actualAmount) external;
    function creditQuoteContribution(address owner, uint256 actualAmount) external;
    function withdrawTokensFor(address owner, uint256 amount, uint256 minResidual)
        external
        returns (uint256 withdrawn, bool nowEmpty);
    function evictDust(uint256 minResidual, uint256 maxNodes)
        external
        returns (uint256 evictedNodes, uint256 evictedAmount);
    function withdrawQuoteFor(address owner, uint256 amount)
        external
        returns (uint256 withdrawn, bool cashSideEmpty);

    // ── trading ──────────────────────────────────────────────────────────
    function priceBuy(address asset, uint256 requestedAmount, address oracle, uint32 epoch, uint256 floor)
        external
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate);

    function priceBuyExactQuote(address asset, uint256 quoteIn, address oracle, uint32 epoch, uint256 floor)
        external
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate);

    function settleBuy(
        address buyer,
        address asset,
        uint256 fillAmount,
        uint256 quotePaid,
        uint256 rate,
        uint256 floor,
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

    // ── anchor freshness keeper (permissionless, band-checked, trade-less) ──
    function pokeAnchor(address asset, address oracle, uint32 epoch) external;

    // ── claims ───────────────────────────────────────────────────────────
    function claimQuote() external;
    function claimQuoteFor(address user) external;
    function claimTokens() external;
    function claimTokensFor(address user) external;
    function setRecycleOptIn(bool optIn) external;

    // ── config (factory-only) ────────────────────────────────────────────
    function setAnchorBand(uint16 bandBps) external;
    function setPaused(bool paused) external;
    function setBuyBack(
        address asset,
        bool enabled,
        uint16 spreadBps,
        uint128 maxPerWindow,
        uint32 windowSecs
    ) external;
    function setPriceSource(uint8 source) external;

    // ── views ────────────────────────────────────────────────────────────
    function previewBuy(address asset, uint256 amount, address oracle, uint32 epoch, uint256 floor)
        external
        view
        returns (bool ok, uint256 fillable, uint256 cost);
    function previewSell(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 grossProceeds);
    function inventoryToken() external view returns (address);
    function buybackAsset() external view returns (address);
    function tokenBalance() external view returns (uint256);
    function poolPaused() external view returns (bool);
    function anchorOf(address asset)
        external
        view
        returns (uint192 rate, uint64 blockNumber, uint32 epoch);
    function staleSurchargeBpsOf(address asset, address oracle, uint32 epoch)
        external
        view
        returns (uint256);

    function oracleHealth(address asset, address oracle)
        external
        view
        returns (bool readable, uint256 freshRate, uint192 anchorRate, uint64 anchorBlock);
    function pendingAnchorOf(address asset)
        external
        view
        returns (uint192 rate, uint64 blockNumber, bool valid);
    function seededAssets() external view returns (address[] memory);
    function positions(address user)
        external
        view
        returns (uint256 tokenPosition, uint256 cashPosition, uint256 claimT);
    function claimableQuoteOf(address user)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);
    function getPlaceInLine(address user, bool cashSide) external view returns (uint256);
}
