// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {HiroFactory} from "../src/HiroFactory.sol";

contract Deploy is Script {
    HiroFactory public hiroFactory;

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("./whitelist.json");

        address[] memory initialWhitelist = abi.decode(vm.parseJson(json), (address[]));

        // Build dynamic agents array by looking for AGENT_ADDRESS_1, AGENT_ADDRESS_2, etc.
        uint256 maxAgents = 2; // adjust as needed
        address[] memory agentsTemp = new address[](maxAgents);
        uint256 count = 0;
        for (uint256 i = 1; i <= maxAgents; i++) {
            string memory key = string(abi.encodePacked("AGENT_ADDRESS_", vm.toString(i)));
            // If the environment variable isn’t set, vm.envString returns an empty string.
            string memory agentStr = vm.envString(key);
            if (bytes(agentStr).length == 0) {
                break;
            }
            agentsTemp[count] = vm.envAddress(key);
            count++;
        }
        // Copy found addresses into a dynamic array of exact length.
        address[] memory agents = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            agents[i] = agentsTemp[i];
        }
        require(count > 0, "No agents configured - check AGENT_ADDRESS env vars");

        vm.startBroadcast();

        hiroFactory = new HiroFactory(initialWhitelist, agents);
        console.log("Hiro Factory deployed at:", address(hiroFactory));

        vm.stopBroadcast();
    }
}
