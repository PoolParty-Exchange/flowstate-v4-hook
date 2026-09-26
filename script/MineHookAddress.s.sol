// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FlowstateC1Hook} from "../src/FlowstateC1Hook.sol";

/// Phase 4 step 1: mine the CREATE2 salt whose deployed address carries the
/// hook's exact permission bits (0x28CC, a flag set proven routable in the
/// live routing study). The mined address depends on the constructor args,
/// so staging and production runs produce different results by design;
/// re-run with production addresses at item 6.
///
///   V4_POOL_MANAGER=0x.. FS_MARKET=0x.. HOOK_OWNER=0x.. AEWETH=0x.. \
///   forge script script/MineHookAddress.s.sol
///
/// Deploy (Phase 4 step 2) uses the canonical CREATE2 deployer
/// (0x4e59b44847b379578588920cA78FbF26c0B4956C) with the printed salt; the
/// resulting address MUST equal the printed one or the V4 PoolManager
/// rejects the hook at pool initialization.
contract MineHookAddress is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external view {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address market = vm.envAddress("FS_MARKET");
        address owner = vm.envAddress("HOOK_OWNER");
        address weth9 = vm.envAddress("AEWETH");
        address tokenJar = vm.envAddress("TOKEN_JAR"); // JUP-621
        uint16 jarFeeBps = uint16(vm.envUint("JAR_FEE_BPS"));
        address listingRegistry = vm.envAddress("LISTING_REGISTRY");
        address listingSettlement = vm.envAddress("LISTING_SETTLEMENT");
        bytes memory constructorArgs =
            abi.encode(poolManager, market, owner, weth9, tokenJar, jarFeeBps, listingRegistry, listingSettlement);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FlowstateC1Hook).creationCode, constructorArgs);

        console2.log("required flag bits: 0x%x", uint256(flags));
        console2.log("constructor: poolManager", poolManager);
        console2.log("constructor: market", market);
        console2.log("constructor: owner", owner);
        console2.log("constructor: weth9", weth9);
        console2.log("mined hook address:", hookAddress);
        console2.log("salt:");
        console2.logBytes32(salt);
    }
}
