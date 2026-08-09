// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FlowstateBeaconSeeder} from "../src/FlowstateBeaconSeeder.sol";

/// Deploys the unprivileged beacon seeder periphery. No CREATE2, no mining,
/// no configuration: the contract is stateless convenience and holds nothing.
///
///   V4_POOL_MANAGER=0x.. FS_MARKET=0x.. \
///   forge script script/DeployBeaconSeeder.s.sol --rpc-url $RH_RPC_URL --broadcast
contract DeployBeaconSeeder is Script {
    function run() external {
        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address market = vm.envAddress("FS_MARKET");

        vm.startBroadcast();
        FlowstateBeaconSeeder seeder = new FlowstateBeaconSeeder(poolManager, market);
        vm.stopBroadcast();

        console2.log("beacon seeder deployed:", address(seeder));
    }
}
