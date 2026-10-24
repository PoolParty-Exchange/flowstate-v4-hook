// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {FlowstatePoolOpener} from "../../src/FlowstatePoolOpener.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {AnchorFloorInput} from "./RealStackDeployer.sol";
import {console2} from "forge-std/console2.sol";

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

    function _pairMarketAsset(bytes32 k) internal view returns (address a) {
        (,,,, a) = hook.pairs(k);
    }

    function _keyOf(address a, address b) internal view returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
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

    // -- Gen-6 (JUP-772, 24 Oct 2026): the Uniswap side of a new token needs no operator ------------

    /// @dev Gen-5 refused a native quote from the market (NativeQuoteUnsupported); Gen-6 serves it the
    ///      way the owner path always did: the market asset is the wrapper, and the pool is initialised.
    function test_nativeQuoteFromMarketRegistersThroughTheWrapper() public {
        market.setQuoteAsset(AEWETH, true);
        bytes32 nativeKey = _key(address(0), address(token));
        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(address(0)), Currency.wrap(address(token)), pool);
        assertTrue(_pairRegistered(nativeKey), "native pair registered");
        assertEq(_pairMarketAsset(nativeKey), AEWETH, "the market asset of a native pair is the wrapper");
        assertTrue(hook.isPairReady(Currency.wrap(address(0)), Currency.wrap(address(token))));
        assertTrue(_slot0Price(_keyOf(address(0), address(token))) != 0, "the native pool is initialised");
    }

    /// @dev ONE ETH door (Hamish, 24 Oct 2026): the market registers the wrapper's pair (an approved ERC-20)
    ///      and the hook opens the token's NATIVE-ETH pair instead, settling in the wrapper; no aeWETH-keyed
    ///      pool is created. Routers wrap and unwrap at the edges (Uniswap and Kyber, measured).
    function test_wrapperPairFromMarketOpensTheNativeDoorOnly() public {
        market.setQuoteAsset(AEWETH, true);
        bytes32 nativeKey = _key(address(0), address(token));
        assertFalse(_pairRegistered(aewethKey));
        assertFalse(_pairRegistered(nativeKey));
        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
        assertTrue(_pairRegistered(nativeKey), "native pair registered");
        assertFalse(_pairRegistered(aewethKey), "no aeWETH-keyed pair: one ETH door");
        assertEq(_pairMarketAsset(nativeKey), AEWETH, "settles in the wrapper");
        assertEq(_pairPool(nativeKey), pool);
        assertTrue(_slot0Price(_keyOf(address(0), address(token))) != 0, "native pool initialised");
        assertEq(_slot0Price(_keyOf(AEWETH, address(token))), 0, "no aeWETH pool exists");
        // idempotent: a second market call changes nothing
        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
        assertEq(_pairSpread(nativeKey), hook.marketRegistrationSpreadBps());
        assertFalse(_pairRegistered(aewethKey));
    }

    /// @dev An owner-tuned native pair is never clobbered by the market's wrapper registration.
    function test_marketWrapperRegistrationNeverClobbersAnOwnerRegisteredNativePair() public {
        market.setQuoteAsset(AEWETH, true);
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), pool, 7);
        vm.prank(address(market));
        hook.registerPairFromMarket(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool);
        assertEq(_pairSpread(_key(address(0), address(token))), 7, "owner spread kept");
        assertFalse(_pairRegistered(aewethKey), "still no aeWETH-keyed pair");
    }

    /// @dev The opener is permissionless and idempotent, and refuses nothing it should accept: an
    ///      initialised pool answers true without a call, an unregistered pair answers false.
    function test_openerIsPermissionlessAndIdempotent() public {
        FlowstatePoolOpener op = FlowstatePoolOpener(payable(address(hook.opener())));
        assertEq(address(op.hook()), address(hook));
        uint160 before = _slot0Price(poolKey);
        assertTrue(before != 0, "fixture pool initialised by registration");
        vm.prank(makeAddr("anyone"));
        assertTrue(op.open(Currency.wrap(USDG), Currency.wrap(address(token))), "already open: true, no call");
        assertEq(_slot0Price(poolKey), before, "price untouched");
        MockInventoryToken stranger = new MockInventoryToken();
        vm.prank(makeAddr("anyone"));
        assertFalse(op.open(Currency.wrap(USDG), Currency.wrap(address(stranger))), "unregistered pair: false, never a revert");
        assertEq(_slot0Price(_keyOf(USDG, address(stranger))), 0, "nothing initialised");
    }

    /// @dev The seed price is the C1 pool's anchor for the pair's market asset in the key's
    ///      orientation; an unseeded anchor seeds 1:1.
    function test_openerSeedPriceFollowsTheAnchor() public {
        FlowstatePoolOpener op = FlowstatePoolOpener(payable(address(hook.opener())));
        assertEq(op.seedPrice(pool, USDG, usdgIsCurrency0), _sqrtPriceForMockRate(), "anchor price");
        assertEq(op.seedPrice(pool, AEWETH, true), uint160(1 << 96), "unseeded asset: 1:1");
        assertEq(op.seedPrice(makeAddr("not-a-pool"), USDG, true), uint160(1 << 96), "unreadable anchor: 1:1");
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
        address newPool = market.createPool(address(newToken), 100e18, 0, _seedFloors(address(newToken)));
        vm.stopPrank();

        bytes32 key = _key(USDG, address(newToken));
        assertTrue(_pairRegistered(key), "createPool hook registration failed");
        assertEq(_pairPool(key), newPool, "createPool registered the wrong Market pool");
        assertTrue(hook.isPairReady(Currency.wrap(USDG), Currency.wrap(address(newToken))));
        // Gen-6: the V4 pool exists from the createPool transaction, at the anchor price the lister set
        bool c0 = USDG < address(newToken);
        FlowstatePoolOpener op = FlowstatePoolOpener(payable(address(hook.opener())));
        assertEq(_slot0Price(_keyOf(USDG, address(newToken))), op.seedPrice(newPool, USDG, c0), "USDG pool initialised at the anchor price");
        assertTrue(_slot0Price(_keyOf(USDG, address(newToken))) != 0);
    }

    /// @dev The whole Uniswap side of a new token from ONE createPool, with no FlowState key anywhere:
    ///      two doors (USDG and native ETH, the aeWETH approval mapping to the native pair), two initialised
    ///      V4 pools, both ready, and no aeWETH-keyed pool.
    function test_createPoolOpensEveryDoor_NoOperator() public {
        vm.prank(address(stack.tl48));
        market.setTrustedHook(address(hook));
        market.setQuoteAsset(AEWETH, true);

        MockInventoryToken newToken = new MockInventoryToken();
        oracle.setRate(address(newToken), USDG, ORACLE_RATE);
        oracle.setRate(address(newToken), AEWETH, 4e14);
        newToken.mint(lister, 100e18);
        vm.startPrank(lister);
        newToken.approve(address(market), type(uint256).max);
        AnchorFloorInput[] memory floors = new AnchorFloorInput[](2);
        floors[0] = AnchorFloorInput({asset: USDG, minRate: uint192(ORACLE_RATE)});
        floors[1] = AnchorFloorInput({asset: AEWETH, minRate: uint192(4e14)});
        uint256 g = gasleft();
        address newPool = market.createPool(address(newToken), 100e18, 0, floors);
        g -= gasleft();
        vm.stopPrank();
        console2.log("createPool gas with two hook pairs and two pool inits:", g);

        assertFalse(_pairRegistered(_key(AEWETH, address(newToken))), "no aeWETH-keyed pair: one ETH door");
        assertEq(_slot0Price(_keyOf(AEWETH, address(newToken))), 0, "no aeWETH pool");
        address[2] memory quotes = [USDG, address(0)];
        for (uint256 i; i < 2; ++i) {
            bytes32 k = _key(quotes[i], address(newToken));
            assertTrue(_pairRegistered(k), "pair registered");
            assertEq(_pairPool(k), newPool, "bound to the new C1 pool");
            assertTrue(hook.isPairReady(Currency.wrap(quotes[i]), Currency.wrap(address(newToken))), "ready");
            assertTrue(_slot0Price(_keyOf(quotes[i], address(newToken))) != 0, "V4 pool initialised");
        }
        assertEq(_pairMarketAsset(_key(address(0), address(newToken))), AEWETH, "native pair settles in the wrapper");
    }

    // -- owner path unchanged --------------------------------------------------

    function test_ownerRegisterPairStillOverwrites() public {
        // pre-existing semantics: the owner path is a retune and DOES overwrite
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), pool, 7);
        assertEq(_pairSpread(usdgKey), 7);
    }
}
