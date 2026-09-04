// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

/// @notice JUP-609 registration/readiness regressions against the real Market registry.
contract JUP609MarketWiringTest is ForkTestBase {
    function _createPoolFor(MockInventoryToken inventory) internal returns (address createdPool) {
        oracle.setRate(address(inventory), USDG, ORACLE_RATE);
        inventory.mint(lister, 100e18);
        vm.startPrank(lister);
        inventory.approve(address(market), type(uint256).max);
        createdPool = market.createPool(address(inventory), 100e18, 0, _seedFloors(address(inventory)));
        vm.stopPrank();
    }

    function test_manualRegistration_validRecognizedPoolInventoryAndQuoteSucceeds() public {
        Currency quote = Currency.wrap(USDG);
        Currency inventory = Currency.wrap(address(token));
        hook.unregisterPair(quote, inventory);

        hook.registerPair(quote, inventory, pool, 7);

        assertTrue(hook.isPairRegistered(quote, inventory));
        assertTrue(hook.isPairReady(quote, inventory));
        assertEq(hook.spreadBpsFor(quote, inventory, 1e6), 7);
    }

    function test_manualRegistration_unknownMarketPoolRejected() public {
        address unknownPool = makeAddr("unknown-market-pool");
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.MarketPoolNotRecognized.selector, unknownPool));
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), unknownPool, 7);
    }

    function test_manualRegistration_inventoryMismatchRejected() public {
        MockInventoryToken otherToken = new MockInventoryToken();
        address otherPool = _createPoolFor(otherToken);

        vm.expectRevert(
            abi.encodeWithSelector(
                FlowstateC1Hook.MarketInventoryMismatch.selector, otherPool, address(token), address(otherToken)
            )
        );
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), otherPool, 7);
    }

    function test_manualRegistration_unapprovedQuoteRejected() public {
        assertFalse(market.approvedQuoteAssets(AEWETH), "fixture: aeWETH must be unapproved");
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.MarketQuoteAssetNotApproved.selector, pool, AEWETH));
        hook.registerPair(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool, 7);
    }

    function test_manualRegistration_zeroPoolCheckPreserved() public {
        vm.expectRevert(FlowstateC1Hook.ZeroAddress.selector);
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), address(0), 7);
    }

    function test_manualRegistration_ownerOnlyPreserved() public {
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert();
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), pool, 7);
    }

    function test_readinessAndExecutionFailClosedAfterQuoteApprovalRevoked() public {
        Currency quote = Currency.wrap(USDG);
        Currency inventory = Currency.wrap(address(token));
        assertTrue(hook.isPairReady(quote, inventory));

        market.setQuoteAsset(USDG, false);

        assertFalse(hook.isPairReady(quote, inventory));
        try this.swapBuyForReadinessCheck(-1_000e6) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.MarketQuoteAssetNotApproved.selector));
        }
    }

    function swapBuyForReadinessCheck(int256 amountSpecified) external {
        _swapBuy(amountSpecified, "");
    }
}
