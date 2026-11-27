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

    function beaconSeeded(bytes32) external pure returns (bool) {
        return true;
    }
}

/// @dev Fills any buy up to `threshold` (tokens = 3 per unit in, MORE than the shortfall's `wanted`
///      implies, as a pool leg priced under the hook rate would) and reports a shortfall above it.
contract ThresholdPM {
    uint256 public threshold;
    address public hookAddr;

    constructor(uint256 t) {
        threshold = t;
    }

    function setHook(address h) external {
        hookAddr = h;
    }

    function unlock(bytes calldata data) external view returns (bytes memory) {
        (, , uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        bytes memory e;
        if (amountIn <= threshold) {
            e = abi.encodeWithSelector(FlowstateC1View.Simulated.selector, amountIn * 3);
        } else {
            // filled = all stock (3 x threshold), wanted = what the hook rate implies (1 per unit in)
            bytes memory inner = abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, threshold * 3, amountIn, uint256(5));
            e = abi.encodeWithSelector(CustomRevert.WrappedError.selector, hookAddr, IHooks.beforeSwap.selector, inner, hex"a9e35b2f");
        }
        assembly {
            revert(add(e, 32), mload(e))
        }
    }

    receive() external payable {}
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

    function test_ShortfallFromAnotherTarget_IsOther() public {
        // v4-core wraps token transfer failures too; a shortfall inside one is not the hook's
        bytes memory inner = abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, uint256(1e30), uint256(1e31), uint256(5));
        pm.setErr(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(0x1234), bytes4(0xa9059cbb), inner, hex""));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertEq(a.reason, v.REASON_OTHER_REVERT());
        assertEq(a.probeCeiling, 0);
    }

    function test_UnwrappedShortfall_IsOther() public {
        pm.setErr(abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, uint256(1e30), uint256(1e31), uint256(5)));
        FlowstateC1View.PoolAnswer memory a = v.answer(key, G);
        assertEq(a.reason, v.REASON_OTHER_REVERT());
    }

    function test_AnswerAll_OneBadKeyDoesNotSinkTheBatch() public {
        pm.setErr(_shortfall(0, 1, 5));
        PoolKey[] memory ks = new PoolKey[](2);
        ks[0] = key;
        ks[1] = key;
        ks[1].hooks = IHooks(address(0xdead));
        FlowstateC1View.PoolAnswer[] memory out = v.answerAll(ks, G);
        assertEq(out[0].reason, 5);
        assertEq(out[1].reason, v.REASON_ANSWER_FAILED());
        assertEq(out[1].otherSelector, FlowstateC1View.WrongHook.selector);
    }

    function test_SimGasTooHigh_Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1View.SimGasTooHigh.selector, type(uint256).max));
        v.answer(key, type(uint256).max);
    }

    /// Daniel's review point 2: a buy can take more tokens than `wanted` implies (filled > wanted),
    /// which used to skip the confirm step. Now the view still finds a confirmed fill.
    function test_FilledAboveWanted_StillConfirms() public {
        ThresholdPM tp = new ThresholdPM(0.25 ether);
        StubHook h2 = new StubHook(address(tp), address(new StubMarket()));
        tp.setHook(address(h2));
        FlowstateC1View v2 = new FlowstateC1View(FlowstateC1Hook(payable(address(h2))));
        vm.deal(address(tp), 1 ether); // reserves 1 ether, so the probe (1 ether) is over the threshold
        PoolKey memory k2 = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x1234)), 0, 60, IHooks(address(h2)));
        FlowstateC1View.PoolAnswer memory a = v2.answer(k2, G);
        emit log_named_uint("maxAmountIn", a.maxAmountIn);
        assertTrue(a.active, "confirmed despite filled > wanted");
        assertEq(a.reason, 0, "reason is 0 when active");
        assertEq(a.probeStop, 5, "the probe's own stop is kept separately");
        assertLe(a.maxAmountIn, 0.25 ether, "never above what fills");
        assertGe(a.maxAmountIn, 0.25 ether * 99 / 100, "found within 1% of the real limit");
        assertEq(a.available, a.maxAmountIn * 3);
    }
}
