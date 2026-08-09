// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlowstateBeaconSeeder} from "../src/FlowstateBeaconSeeder.sol";
import {FlowstateC1Hook} from "../src/FlowstateC1Hook.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// Lights a pool's visibility beacon: the single permitted liquidityDelta == 1
/// dust add (JUP-519). The BROADCASTER pays the dust (a few wei of PAY_TOKEN)
/// and the gas — never protocol capital; on staging the ops wallet acts as the
/// holder, in production this is the first depositor's seedAndDeposit.
///
/// If PAY_TOKEN is the WETH9 wrapper and the broadcaster holds fewer than 16
/// wei of it, the script wraps 16 wei of native first (value-negligible).
///
///   HOOK=0x.. SEEDER=0x.. PAIR_TOKEN=0x.. AEWETH=0x.. PAY_TOKEN=0x.. \
///   forge script script/SeedBeacon.s.sol --rpc-url $RH_RPC_URL --broadcast
contract SeedBeacon is Script {
    function run() external {
        address hook = vm.envAddress("HOOK");
        address seederAddr = vm.envAddress("SEEDER");
        address token = vm.envAddress("PAIR_TOKEN");
        address weth9 = vm.envAddress("AEWETH");
        address payToken = vm.envAddress("PAY_TOKEN");
        FlowstateBeaconSeeder seeder = FlowstateBeaconSeeder(seederAddr);

        bool quoteIsC0 = weth9 < token;
        (Currency c0, Currency c1) =
            quoteIsC0 ? (Currency.wrap(weth9), Currency.wrap(token)) : (Currency.wrap(token), Currency.wrap(weth9));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});

        vm.startBroadcast();

        // idempotent 16-wei top-up: inside startBroadcast the script frame's
        // msg.sender is not the broadcaster, so read no balances — just wrap.
        if (payToken == weth9) {
            IWETH9(weth9).deposit{value: 16}();
        }
        IERC20(payToken).approve(seederAddr, 16);
        seeder.seed(key, payToken);

        vm.stopBroadcast();

        bool lit = FlowstateC1Hook(payable(hook)).beaconSeeded(key.toId());
        console2.log("beaconSeeded:", lit);
        require(lit, "beacon did not light");
    }
}
