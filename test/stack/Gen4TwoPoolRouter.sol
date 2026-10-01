// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only router for the JUP-698 stack harness: several swaps in ONE PoolManager unlock,
///         the way an aggregator splits a route across the two ETH pools of a token (design E).
///         Swaps run in the given order; then every currency's LIVE delta is settled or taken, as
///         v4-periphery's SETTLE_ALL / TAKE_ALL do. Native is paid from msg.value (settle with value,
///         no sync) and any unused native is refunded to the caller; ERC-20s are pulled from the caller.
contract Gen4TwoPoolRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Leg {
        PoolKey key;
        SwapParams params;
    }

    struct Call {
        address payer;
        Leg[] legs;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapAll(Leg[] calldata legs) external payable {
        manager.unlock(abi.encode(Call(msg.sender, legs)));
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Call memory c = abi.decode(data, (Call));
        for (uint256 i; i < c.legs.length; ++i) {
            manager.swap(c.legs[i].key, c.legs[i].params, "");
        }
        for (uint256 i; i < c.legs.length; ++i) {
            _clear(c.legs[i].key.currency0, c.payer);
            _clear(c.legs[i].key.currency1, c.payer);
        }
        return "";
    }

    function _clear(Currency currency, address payer) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-delta));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }

    receive() external payable {}
}
