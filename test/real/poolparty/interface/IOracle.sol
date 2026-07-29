// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOracle
 * @dev Interface for price oracle that provides token to ETH conversion rates
 * @notice Used to get the current market price of tokens in ETH terms
 */
interface IOracle {
    /**
     * @notice Gets the exchange rate of a token to ETH
     * @dev Returns the amount of wei that 1 token unit is worth
     * @param srcToken Token to get the rate for
     * @param _useWrappers Whether to use wrapped versions of tokens
     * @return rate The exchange rate (wei per token unit with token's decimals)
     */
    function getRateToEth(IERC20 srcToken, bool _useWrappers) external view returns (uint256 rate);

    /**
     * @notice Gets the exchange rate of a token to another token
     * @dev Returns the amount of dstToken that 1 srcToken unit is worth
     * @param srcToken Token to get the rate for
     * @param dstToken Token to get the rate for
     * @param _useWrappers Whether to use wrapped versions of tokens
     * @return rate The exchange rate (dstToken per srcToken unit with srcToken's decimals)
     */
    function getRate(IERC20 srcToken, IERC20 dstToken, bool _useWrappers) external view returns (uint256 rate);
}