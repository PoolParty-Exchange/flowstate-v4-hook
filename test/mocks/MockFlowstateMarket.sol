// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlowstateMarketMinimal} from "../../src/interfaces/IFlowstateMarketMinimal.sol";
import {IFlowstateBuyFunder} from "../../src/interfaces/IFlowstateBuyFunder.sol";

/// @notice Stand-in for FlowstateMarket: fixed-rate, pull-exact, all-or-nothing.
///         Holds the token inventory itself and acts as its own pool record, but
///         mirrors the REAL market's Phase 1 entry-point semantics exactly:
///         - buyFromPoolExactQuote inverts with floor rounding then recomputes the
///           pull as the ceil cost of the tokens delivered (quotePaid <= quoteIn);
///         - buyFromPoolExactOut runs the IFlowstateBuyFunder callback under the
///           real market's skip rules (caller has code AND balance or allowance
///           short) before the pull-exact transferFrom.
/// @dev Pricing: tokensOut = quoteIn * rateNum / rateDen (floor);
///      quoteCost = ceil(tokenAmount * rateDen / rateNum). The asymmetric rounding
///      mirrors the real market: the buyer side never underpays.
contract MockFlowstateMarket is IFlowstateMarketMinimal {
    using SafeERC20 for IERC20;

    error UnknownPool();
    error ZeroAmount();
    error FillShortfall();

    event MockBuy(address indexed buyer, uint256 quotePaid, uint256 tokensFilled);

    IERC20 public immutable quoteAsset;
    IERC20 public immutable inventoryToken;
    /// @dev Mutable (test-only) so a suite can pick a rate whose inversion genuinely
    ///      loses dust to the floor — the hook's rounding proofs need a market where
    ///      quotePaid < quoteIn is reachable. Not part of the real market surface.
    uint256 public rateNum;
    uint256 public rateDen;

    constructor(address _quoteAsset, address _inventoryToken, uint256 _rateNum, uint256 _rateDen) {
        quoteAsset = IERC20(_quoteAsset);
        inventoryToken = IERC20(_inventoryToken);
        rateNum = _rateNum;
        rateDen = _rateDen;
    }

    function setRate(uint256 _rateNum, uint256 _rateDen) external {
        rateNum = _rateNum;
        rateDen = _rateDen;
    }

    function buyFromPool(address pool, uint256 amount, string calldata, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        if (pool != address(this)) revert UnknownPool();
        if (amount == 0) revert ZeroAmount();
        // legacy partial-fill semantics: cap at inventory
        uint256 available = inventoryToken.balanceOf(address(this));
        tokensFilled = amount < available ? amount : available;
        if (tokensFilled == 0) revert FillShortfall();
        quotePaid = _quoteCost(tokensFilled);
        _fill(buyer, quotePaid, tokensFilled);
    }

    function buyFromPoolExactQuote(address pool, uint256 quoteIn, string calldata, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        if (pool != address(this)) revert UnknownPool();
        if (quoteIn == 0) revert ZeroAmount();
        tokensFilled = quoteIn * rateNum / rateDen; // invert, floor (against the buyer)
        if (tokensFilled == 0) revert ZeroAmount();
        if (tokensFilled > inventoryToken.balanceOf(address(this))) revert FillShortfall(); // all-or-nothing
        quotePaid = _quoteCost(tokensFilled); // recompute, ceil — always <= quoteIn
        _fill(buyer, quotePaid, tokensFilled);
    }

    function buyFromPoolExactOut(address pool, uint256 tokenAmountOut, string calldata, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid)
    {
        if (pool != address(this)) revert UnknownPool();
        if (tokenAmountOut == 0) revert ZeroAmount();
        if (tokenAmountOut > inventoryToken.balanceOf(address(this))) revert FillShortfall(); // all-or-nothing
        tokensFilled = tokenAmountOut;
        quotePaid = _quoteCost(tokenAmountOut);
        // real-market callback rules: only a code-bearing caller that cannot already
        // cover the cost is asked to fund itself
        if (
            msg.sender.code.length != 0
                && (
                    quoteAsset.balanceOf(msg.sender) < quotePaid
                        || quoteAsset.allowance(msg.sender, address(this)) < quotePaid
                )
        ) {
            IFlowstateBuyFunder(msg.sender).fundBuy(address(quoteAsset), quotePaid);
        }
        _fill(buyer, quotePaid, tokensFilled);
    }

    function _quoteCost(uint256 tokenAmount) internal view returns (uint256) {
        return (tokenAmount * rateDen + rateNum - 1) / rateNum;
    }

    function _fill(address buyer, uint256 quotePaid, uint256 tokensFilled) internal {
        quoteAsset.safeTransferFrom(msg.sender, address(this), quotePaid);
        inventoryToken.safeTransfer(buyer, tokensFilled);
        emit MockBuy(buyer, quotePaid, tokensFilled);
    }
}
