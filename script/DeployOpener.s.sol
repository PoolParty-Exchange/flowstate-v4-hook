// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FlowstatePoolOpener} from "../src/FlowstatePoolOpener.sol";

/// Gen-6 step 0: deploy the hook's opener BEFORE the hook, with a plain CREATE from the deployer, so
/// its address depends only on the deployer's nonce and can be fed to MineHookAddress as OPENER
/// before the hook exists, while the opener itself carries the hook's mined address.
///
/// Sequence: predict the opener address (deployer, nonce N) -> mine the hook with OPENER = that
/// address -> run this script at nonce N with EXPECTED_HOOK = the mined address -> DeployHook at a
/// later nonce through the CREATE2 factory. The script reverts if the deployed address differs from
/// the predicted one (a nonce moved in between: re-predict and re-mine).
///
///   V4_POOL_MANAGER=0x.. EXPECTED_HOOK=0x.. AEWETH=0x.. EXPECTED_OPENER=0x.. \
///   forge script script/DeployOpener.s.sol --rpc-url $RH_RPC_URL --broadcast
contract DeployOpener is Script {
    function run() external {
        address poolManager = vm.envAddress("V4_POOL_MANAGER");
        address expectedHook = vm.envAddress("EXPECTED_HOOK");
        address weth9 = vm.envAddress("AEWETH");
        address expectedOpener = vm.envAddress("EXPECTED_OPENER");

        vm.startBroadcast();
        FlowstatePoolOpener opener = new FlowstatePoolOpener(poolManager, expectedHook, weth9);
        vm.stopBroadcast();

        require(address(opener) == expectedOpener, "deployed opener != predicted address");
        console2.log("opener deployed:", address(opener));
        console2.log("bound to hook:", expectedHook);
    }
}
