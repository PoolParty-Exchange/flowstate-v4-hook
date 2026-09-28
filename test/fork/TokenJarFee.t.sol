// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {ListingStandIn} from "./ListingStandIn.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

/// JUP-621: the hook pays Uniswap's TokenJar an immutable fee on every fill, carved
/// out of the spread so the buyer's price is unchanged. These tests pin the four
/// properties Uniswap Labs asked for: paid on every fill shape, in the same
/// transaction, from the spread (never from inventory or the buyer), and impossible
/// to configure away.
///
/// 29 Sep 2026: the fill tests (exact input, exact output, one fee per fill, the fee on an
/// exact-depth fill, spread == fee leaves the hook nothing, no fee on a short fill) ran the
/// deleted Gen-3 path and are retired. The Gen-4 fill tests are in
/// test/stack/gen4-stack.test.cjs ("TokenJar fee"), on pool, listing and mixed fills in both
/// directions against a jar-free twin. What stays here is the configuration surface.
contract TokenJarFeeForkTest is ForkTestBase {
    /// Production values: 8 bps to the jar out of a 16 bps spread.
    function _jarFeeBps() internal pure override returns (uint16) {
        return JAR_FEE_BPS;
    }

    function _fixtureSpreadBps() internal pure override returns (uint16) {
        return 16;
    }

    function test_Immutables_WiredFromConstructor() public view {
        assertEq(hook.tokenJar(), TOKEN_JAR, "jar");
        assertEq(hook.jarFeeBps(), JAR_FEE_BPS, "bps");
    }

    /// No configuration can push a spread below the jar fee: base spread, floor and
    /// registration default all refuse, so the fee can always be carved from the spread.
    /// (Until 29 Sep 2026 this also swapped at a spread equal to the fee to show the hook keeps
    /// nothing; that half ran the deleted Gen-3 path and is in the stack harness now.)
    function test_SpreadSettersCannotDropBelowJarFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), JAR_FEE_BPS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setBaseSpreadFloor(JAR_FEE_BPS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setMarketRegistrationSpread(JAR_FEE_BPS - 1);
        // exactly the jar fee is the lowest legal spread
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), JAR_FEE_BPS);
        assertEq(hook.spreadBpsFor(Currency.wrap(USDG), Currency.wrap(address(token)), 1e6), JAR_FEE_BPS);
    }

    /// Constructor refuses a zero jar and a fee above the registration default. The listing
    /// wiring is valid (stand-ins), so each revert is the guard under test and nothing else.
    function test_Constructor_Guards() public {
        (address standInRegistry, address standInSettlement) = ListingStandIn.deploy(address(market));
        (, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, address(0), JAR_FEE_BPS, standInRegistry, standInSettlement)
        );
        vm.expectRevert(FlowstateC1Hook.ZeroAddress.selector);
        new FlowstateC1Hook{salt: salt}(
            POOL_MANAGER, address(market), address(this), AEWETH, address(0), JAR_FEE_BPS, standInRegistry, standInSettlement
        );
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, uint16(17), standInRegistry, standInSettlement)
        );
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, 16, 17, hook.MAX_SPREAD_BPS()));
        new FlowstateC1Hook{salt: salt2}(
            POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, uint16(17), standInRegistry, standInSettlement
        );
    }
}
