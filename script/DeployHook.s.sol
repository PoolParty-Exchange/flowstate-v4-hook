// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FlowstateC1Hook} from "../src/FlowstateC1Hook.sol";

/// Phase 4 step 2: deterministic deploy + configuration.
///
/// Forge routes `new{salt: ...}` through the canonical CREATE2 deployer
/// (0x4e59b44847b379578588920cA78FbF26c0B4956C) when broadcasting, which is
/// the same deployer MineHookAddress.s.sol mined against, so the deployed
/// address MUST equal EXPECTED_HOOK or this script reverts before any
/// configuration happens.
///
///   SALT=0x.. EXPECTED_HOOK=0x.. V4_POOL_MANAGER=0x.. FS_MARKET=0x.. \
///   HOOK_OWNER=0x.. AEWETH=0x.. TOKEN_JAR=0x.. JAR_FEE_BPS=8 \
///   LISTING_REGISTRY=0x.. LISTING_SETTLEMENT=0x.. OPENER=0x.. \
///   forge script script/DeployHook.s.sol --rpc-url $RH_RPC_URL --broadcast
///
/// This script deploys only. The Gen-7 hook has no reseller-code setter:
/// PoolManager's direct swap caller is resolved through the Market on each swap.
/// Registering pairs, selecting the trusted hook, and any later dedicated-router
/// mappings are separately reviewed Safe actions. No partner mapping is inferred
/// from this deployment, and fee-bearing activation needs approved Market terms.
/// The release package supplies the actual phased order and unsigned review.
contract DeployHook is Script {
    function run() external {
        bytes32 salt = vm.envBytes32("SALT");
        address expected = vm.envAddress("EXPECTED_HOOK");
        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address market = vm.envAddress("FS_MARKET");
        address owner = vm.envAddress("HOOK_OWNER");
        address weth9 = vm.envAddress("AEWETH");
        vm.startBroadcast();

        // JUP-621: immutable TokenJar fee (Uniswap allowlist criterion). Both values are
        // baked into the CREATE2 init code, so they are part of the mined salt too.
        address tokenJar = vm.envAddress("TOKEN_JAR");
        uint16 jarFeeBps = uint16(vm.envUint("JAR_FEE_BPS"));
        address listingRegistry = vm.envAddress("LISTING_REGISTRY");
        address listingSettlement = vm.envAddress("LISTING_SETTLEMENT");
        address opener = vm.envAddress("OPENER"); // Gen-6: deployed first (DeployOpener.s.sol), code-bearing
        require(opener.code.length != 0, "opener not deployed");
        FlowstateC1Hook hook = new FlowstateC1Hook{salt: salt}(
            poolManager, market, owner, weth9, tokenJar, jarFeeBps, listingRegistry, listingSettlement, opener
        );
        require(address(hook) == expected, "deployed address != mined address");
        require(hook.owner() == owner, "owner mismatch");

        vm.stopBroadcast();

        console2.log("hook deployed:", address(hook));
        console2.log("owner (Safe):", owner);
        console2.log("next: review Safe pair registration, Market resolver/readback, trusted-hook switch and separate activation gates");
    }
}
