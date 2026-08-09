// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
///   HOOK_OWNER=0x.. AEWETH=0x.. PAIR_TOKEN=0x.. MARKET_POOL=0x.. \
///   RESELLER_CODE=v4hook BASE_SPREAD_BPS=30 \
///   forge script script/DeployHook.s.sol --rpc-url $RH_RPC_URL --broadcast
///
/// Ops order (staging rehearsal = production runbook):
///   1. Register the reseller code on the MARKET first
///      (deploy/manage-reseller.js in PoolParty_Contracts), so hook buys
///      attribute from the first fill.
///   2. Run this script: deploys the hook, registers the (aeWETH, token)
///      pair against its C1 market pool, sets the reseller code.
///   3. Initialize the V4 pool with this hook in the PoolKey (Phase 5
///      script, next step) and observe routing.
contract DeployHook is Script {
    function run() external {
        bytes32 salt = vm.envBytes32("SALT");
        address expected = vm.envAddress("EXPECTED_HOOK");
        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address market = vm.envAddress("FS_MARKET");
        address owner = vm.envAddress("HOOK_OWNER");
        address weth9 = vm.envAddress("AEWETH");
        address pairToken = vm.envAddress("PAIR_TOKEN");
        address marketPool = vm.envAddress("MARKET_POOL");
        string memory resellerCode = vm.envString("RESELLER_CODE");
        uint16 baseSpreadBps = uint16(vm.envUint("BASE_SPREAD_BPS"));

        vm.startBroadcast();

        FlowstateC1Hook hook = new FlowstateC1Hook{salt: salt}(poolManager, market, owner, weth9);
        require(address(hook) == expected, "deployed address != mined address");

        // quote = aeWETH (the wrapper; native-quoted V4 pools reach the same
        // C1 pool through it), token = the inventory token.
        hook.registerPair(Currency.wrap(weth9), Currency.wrap(pairToken), marketPool, baseSpreadBps);
        hook.setResellerCode(resellerCode);

        vm.stopBroadcast();

        console2.log("hook deployed:", address(hook));
        console2.log("pair registered: quote aeWETH, token", pairToken, "-> market pool", marketPool);
        console2.log("reseller code set:", resellerCode);
    }
}
