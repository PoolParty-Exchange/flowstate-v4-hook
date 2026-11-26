// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {FlowstateC1View} from "../../src/lens/FlowstateC1View.sol";

/// @dev A PoolManager stand-in whose unlock reverts with whatever bytes the test sets, standing in
///      for a hostile listed token whose revert data bubbles out of the hook unchanged.
contract RevertingPM {
    bytes public err;
    uint256 public bigLen;

    function setErr(bytes memory e) external {
        err = e;
    }

    function setBig(uint256 n) external {
        bigLen = n;
    }

    function unlock(bytes calldata) external view returns (bytes memory) {
        bytes memory e = err;
        if (bigLen != 0) {
            e = abi.encodeWithSelector(CustomRevert.WrappedError.selector, msg.sender, bytes4(0x575e24b4), new bytes(bigLen), hex"a9e35b2f");
        }
        assembly {
            revert(add(e, 32), mload(e))
        }
    }

    receive() external payable {}
}

contract StubMarket {
    function previewHookRate(address, address) external pure returns (bool, uint256) {
        return (true, 1e12);
    }
}

contract StubHook {
    address public poolManager;
    address public market;

    constructor(address pm, address m) {
        poolManager = pm;
        market = m;
    }

    function pairs(bytes32) external pure returns (address, bool, bool, uint16, address) {
        return (address(0xBEEF), true, true, uint16(50), address(0xEE));
    }
}

/// @notice Decoding of simulation reverts (review of 26 Nov 2026, findings B3 and B4): a forged
///         hook shortfall must never read as stock, and malformed data must never break a batch.
contract C1ViewDecodeTest is Test {
    RevertingPM pm;
    StubHook hk;
    FlowstateC1View v;
    PoolKey key;
    uint256 constant G = 1_000_000;

    function setUp() public {
        pm = new RevertingPM();
        hk = new StubHook(address(pm), address(new StubMarket()));
        v = new FlowstateC1View(FlowstateC1Hook(payable(address(hk))));
        vm.deal(address(pm), 1 ether); // non-zero reserves for the native quote
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x1234)), 0, 60, IHooks(address(hk)));
    }

    function _wrap(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(hk), IHooks.beforeSwap.selector, inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _shortfall(uint256 filled, uint256 wanted, uint256 stop) internal view returns (bytes memory) {
        return _wrap(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, filled, wanted, stop));
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function test_ForgedStopZero_IsNotAFill() public {
        pm.setErr(_shortfall(1e30, 0, 0));
        (uint256[] memory outs, uint8[] memory rs,) = v.quote(key, _one(1), G);
        assertEq(outs[0], 0);
        assertEq(rs[0], v.REASON_OTHER_REVERT());
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertFalse(a.active);
        assertEq(a.available, 0);
        assertFalse(a.availableIsFloor);
    }

    function test_ForgedStock_IsNeverConfirmed() public {
        // a forged stop 5 claiming huge stock: the confirming buy fails the same way, so nothing counts
        pm.setErr(_shortfall(1e30, 1e31, 5));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertFalse(a.active);
        assertEq(a.available, 0);
        assertEq(a.maxAmountIn, 0);
        assertEq(a.reason, v.REASON_UNCONFIRMED());
        assertEq(a.probeCeiling, 1e30, "the unconfirmed figure is shown as such");
    }

    function test_ForgedStockWithZeroWanted_Inactive() public {
        pm.setErr(_shortfall(1e30, 0, 5));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertFalse(a.active);
        assertEq(a.available, 0);
    }

    function test_TruncatedInner_DoesNotBreakBatch() public {
        pm.setErr(_wrap(abi.encodePacked(FlowstateC1Hook.ExactInputShortfall.selector)));
        PoolKey[] memory ks = new PoolKey[](2);
        ks[0] = key;
        ks[1] = key;
        FlowstateC1View.PoolAnswer[] memory out = v.answerAll(ks, G);
        assertEq(out[0].reason, v.REASON_OTHER_REVERT());
        assertEq(out[1].reason, v.REASON_OTHER_REVERT());
    }

    function test_MalformedWrapper_DoesNotRevert() public {
        pm.setErr(abi.encodePacked(CustomRevert.WrappedError.selector, hex"0102"));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertEq(a.reason, v.REASON_OTHER_REVERT());
    }

    function test_StopOutOfRange_IsOther() public {
        pm.setErr(_shortfall(1, 1, 300));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertEq(a.reason, v.REASON_OTHER_REVERT());
        assertFalse(a.active);
    }

    function test_EmptyRevert_IsOther() public {
        pm.setErr("");
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertEq(a.reason, v.REASON_OTHER_REVERT());
        assertEq(a.otherSelector, bytes4(0));
    }

    function test_LargeRevertData_BoundedGas() public {
        pm.setBig(32_000);
        uint256 g = gasleft();
        v.answer(key, G);
        uint256 used = g - gasleft();
        emit log_named_uint("answer gas with a 32 KB revert reason", used);
        assertLt(used, 1_000_000, "no per-byte copy");
    }

    function test_ZeroSimGas_Rejected() public {
        vm.expectRevert(FlowstateC1View.SimGasRequired.selector);
        v.answer(key, 0);
        vm.expectRevert(FlowstateC1View.SimGasRequired.selector);
        v.quote(key, _one(1), 0);
    }

    function test_ForgedHugeFilled_NoOverflowAndBatchSurvives() public {
        // filled above wanted (never true for the genuine hook) used to overflow the confirm sizing
        pm.setErr(_shortfall(type(uint256).max / 2, 1, 5));
        PoolKey[] memory ks = new PoolKey[](2);
        ks[0] = key;
        ks[1] = key;
        FlowstateC1View.PoolAnswer[] memory out = v.answerAll(ks, G);
        assertFalse(out[0].active);
        assertEq(out[0].available, 0);
        assertFalse(out[1].active);
    }

    function test_HugeRevertData_CopyIsCapped() public {
        pm.setBig(200_000);
        uint256 g = gasleft();
        v.answer(key, G);
        uint256 used = g - gasleft();
        emit log_named_uint("answer gas with a 200 KB revert reason", used);
        assertLt(used, 1_500_000, "revert data copy is capped");
    }

    function test_OuterGasTooLow_Refuses() public {
        pm.setErr(_shortfall(0, 0, 5));
        try v.answer{gas: 1_000_000}(key, G) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), FlowstateC1View.OuterGasTooLow.selector, "refused for outer gas, not another revert");
        }
    }
}
