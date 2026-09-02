// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

/// @notice JUP-587: the market-trusted auto-registration path used by createPool.
///         Scope per Wilko's GO (24 Aug): narrow, idempotent, tightly permissioned.
///         The base fixture already has the OWNER-registered USDG/token pair at
///         spread 0, which doubles as the no-clobber target here.
contract RegisterFromMarketTest is ForkTestBase {
    event MarketRegistrationSpreadUpdated(uint16 previous, uint16 current);

    bytes32 usdgKey;
    bytes32 aewethKey;

    function setUp() public override {
        super.setUp();
        usdgKey = _key(USDG, address(token));
        aewethKey = _key(AEWETH, address(token));
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(Currency.wrap(c0), Currency.wrap(c1)));
    }

    function _pairPool(bytes32 k) internal view returns (address p) {
        (p,,,,) = hook.pairs(k);
    }

    function _pairRegistered(bytes32 k) internal view returns (bool r) {
        (,, r,,) = hook.pairs(k);
    }

    function _pairSpread(bytes32 k) internal view returns (uint16 s) {
        (,,, s,) = hook.pairs(k);
    }

    // -- access control ------------------------------------------------------

    function test_nonMarketCallerReverts_evenTheOwner() public {
        // this test contract IS the hook owner; the market path must still refuse it
        vm.expectRevert(FlowstateC1Hook.NotMarket.selector);
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(FlowstateC1Hook.NotMarket.selector);
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
    }

    // -- registration behaviour ----------------------------------------------

    function test_registersFreshPairWithConfiguredSpread() public {
        assertFalse(_pairRegistered(aewethKey), "fixture: aeWETH pair must start unregistered");
        market.setQuoteAsset(AEWETH, true);

        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);

        assertTrue(_pairRegistered(aewethKey), "not registered");
        assertEq(_pairSpread(aewethKey), hook.marketRegistrationSpreadBps(), "spread != configured default");
        assertEq(_pairPool(aewethKey), pool, "wrong market pool");
    }

    function test_defaultSpreadIsSixteenBps() public view {
        // launch parity with the manually registered CASHCAT/HOODRAT pairs
        assertEq(hook.marketRegistrationSpreadBps(), 16);
    }

    function test_idempotent_neverClobbersOwnerConfig() public {
        // owner registered USDG/token at spread 0 in setUp with the real pool;
        // a market-path retry with DIFFERENT config must change nothing.
        assertTrue(_pairRegistered(usdgKey));
        assertEq(_pairSpread(usdgKey), 0);

        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(USDG), Currency.wrap(address(token)), makeAddr("other-pool"));

        assertEq(_pairSpread(usdgKey), 0, "spread clobbered");
        assertEq(_pairPool(usdgKey), pool, "marketPool clobbered");
    }

    function test_nativeQuoteRejected() public {
        vm.prank(address(market));
        vm.expectRevert(FlowstateC1Hook.NativeQuoteUnsupported.selector);
        hook.registerPairFromMarket(Currency.wrap(address(0)), Currency.wrap(address(token)), pool);
    }

    function test_zeroMarketPoolRejected() public {
        vm.prank(address(market));
        vm.expectRevert(FlowstateC1Hook.ZeroAddress.selector);
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), address(0));
    }

    // -- spread configuration --------------------------------------------------

    function test_setMarketRegistrationSpread_appliesToNextRegistration() public {
        market.setQuoteAsset(AEWETH, true);
        vm.expectEmit(false, false, false, true, address(hook));
        emit MarketRegistrationSpreadUpdated(16, 40);
        hook.setMarketRegistrationSpread(40);
        assertEq(hook.marketRegistrationSpreadBps(), 40);

        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
        assertEq(_pairSpread(aewethKey), 40);
    }

    function test_setMarketRegistrationSpread_ownerOnly() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.setMarketRegistrationSpread(40);
    }

    function test_setMarketRegistrationSpread_hardCapEnforced() public {
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, uint16(1001), uint16(0), uint16(1000))
        );
        hook.setMarketRegistrationSpread(1001);
    }

    function test_floorSelfHeal_registrationUsesFloorNotRevert() public {
        // raise the floor ABOVE the market-registration spread: the market path
        // must degrade to the floor, never revert (a revert here would bubble as
        // a createPool auto-registration failure on every new pool).
        hook.setBaseSpreadFloor(50);
        assertLt(hook.marketRegistrationSpreadBps(), 50);
        market.setQuoteAsset(AEWETH, true);

        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
        assertEq(_pairSpread(aewethKey), 50, "floor not applied");
    }

    function test_marketCreatePoolAutoRegistrationStillSucceedsWithValidation() public {
        vm.prank(address(stack.tl48));
        market.setTrustedHook(address(hook));

        MockInventoryToken newToken = new MockInventoryToken();
        oracle.setRate(address(newToken), USDG, ORACLE_RATE);
        newToken.mint(lister, 100e18);
        vm.startPrank(lister);
        newToken.approve(address(market), type(uint256).max);
        address newPool = market.createPool(address(newToken), 100e18, 0);
        vm.stopPrank();

        bytes32 key = _key(USDG, address(newToken));
        assertTrue(_pairRegistered(key), "createPool hook registration failed");
        assertEq(_pairPool(key), newPool, "createPool registered the wrong Market pool");
        assertTrue(hook.isPairReady(Currency.wrap(USDG), Currency.wrap(address(newToken))));
    }

    // -- owner path unchanged --------------------------------------------------

    function test_ownerRegisterPairStillOverwrites() public {
        // pre-existing semantics: the owner path is a retune and DOES overwrite
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), pool, 7);
        assertEq(_pairSpread(usdgKey), 7);
    }
}
