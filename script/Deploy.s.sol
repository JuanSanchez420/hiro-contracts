// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {HiroFactory} from "../src/HiroFactory.sol";

contract Deploy is Script {
    HiroFactory public hiroFactory;

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("./whitelist.json");
        address[] memory initialTargets = abi.decode(vm.parseJson(json), (address[]));

        vm.startBroadcast();
        hiroFactory = new HiroFactory(initialTargets);
        console.log("Hiro Factory deployed at:", address(hiroFactory));
        vm.stopBroadcast();
    }
}
