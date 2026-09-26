// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only router for the JUP-698 stack harness. It settles and takes the LIVE currency
///         deltas after the swap, as v4-periphery's SETTLE_ALL / TAKE_ALL do (they pay `_getFullDebt`),
///         so a hook refund through settleFor reduces what the swapper pays. PoolSwapTest instead
///         requires the live delta to equal the swap's returned delta, which any hook refund breaks.
///         ERC-20 currencies only.
contract Gen4LiveDeltaRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Call {
        address payer;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, SwapParams calldata params) external returns (int256 paid0, int256 paid1) {
        (paid0, paid1) = abi.decode(manager.unlock(abi.encode(Call(msg.sender, key, params))), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Call memory c = abi.decode(data, (Call));
        manager.swap(c.key, c.params, "");
        int256 d0 = _clear(c.key.currency0, c.payer);
        int256 d1 = _clear(c.key.currency1, c.payer);
        return abi.encode(d0, d1);
    }

    function _clear(Currency currency, address payer) internal returns (int256 delta) {
        delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }
}
