// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlowstateMarketMinimal} from "../../src/interfaces/IFlowstateMarketMinimal.sol";

/// @notice Phase 0 stand-in for FlowstateMarket: fixed-rate, pull-exact, all-or-nothing.
///         Holds the token inventory itself and acts as its own pool record. Phase 1
///         replaces this with the real market + FlowstatePool; the hook-facing interface
///         is identical.
/// @dev Pricing: tokensOut = quoteIn * rateNum / rateDen (rounded down);
///      quoteCost = ceil(tokenAmount * rateDen / rateNum). The asymmetric rounding
///      mirrors a real market: the buyer side never underpays.
contract MockFlowstateMarket is IFlowstateMarketMinimal {
    using SafeERC20 for IERC20;

    error UnknownPool();
    error ZeroAmount();
    error InsufficientInventory(uint256 requested, uint256 available);

    event MockBuy(address indexed buyer, uint256 quotePaid, uint256 tokensFilled);

    IERC20 public immutable quoteAsset;
    IERC20 public immutable inventoryToken;
    uint256 public immutable rateNum;
    uint256 public immutable rateDen;

    constructor(address _quoteAsset, address _inventoryToken, uint256 _rateNum, uint256 _rateDen) {
        quoteAsset = IERC20(_quoteAsset);
        inventoryToken = IERC20(_inventoryToken);
        rateNum = _rateNum;
        rateDen = _rateDen;
    }

    function buyFromPool(address pool, uint256 amount, string calldata, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        if (pool != address(this)) revert UnknownPool();
        if (amount == 0) revert ZeroAmount();
        quotePaid = _quoteCost(amount);
        _fill(buyer, quotePaid, amount);
        tokensFilled = amount;
    }

    function buyFromPoolExactQuote(address pool, uint256 quoteIn, string calldata, address buyer)
        external
        returns (uint256 tokensFilled)
    {
        if (pool != address(this)) revert UnknownPool();
        if (quoteIn == 0) revert ZeroAmount();
        tokensFilled = quoteIn * rateNum / rateDen;
        _fill(buyer, quoteIn, tokensFilled);
    }

    function quoteBuyFromPool(address pool, uint256 amount) external view returns (uint256 quoteCost) {
        if (pool != address(this)) revert UnknownPool();
        quoteCost = _quoteCost(amount);
    }

    function _quoteCost(uint256 tokenAmount) internal view returns (uint256) {
        return (tokenAmount * rateDen + rateNum - 1) / rateNum;
    }

    function _fill(address buyer, uint256 quotePaid, uint256 tokensFilled) internal {
        uint256 available = inventoryToken.balanceOf(address(this));
        if (tokensFilled > available) revert InsufficientInventory(tokensFilled, available);
        quoteAsset.safeTransferFrom(msg.sender, address(this), quotePaid);
        inventoryToken.safeTransfer(buyer, tokensFilled);
        emit MockBuy(buyer, quotePaid, tokensFilled);
    }
}
