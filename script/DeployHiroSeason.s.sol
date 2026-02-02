// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {HiroSeason} from "../src/HiroSeason.sol";

contract DeployHiroSeason is Script {
    // Base mainnet addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    HiroSeason public hiroSeason;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        hiroSeason = new HiroSeason(WETH, POSITION_MANAGER, SWAP_ROUTER);

        console.log("HiroSeason deployed at:", address(hiroSeason));
        console.log("HiroToken deployed at:", address(hiroSeason.hiroToken()));

        vm.stopBroadcast();
    }
}
