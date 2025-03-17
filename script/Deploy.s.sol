// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";
import "lib/slipstream/contracts/core/interfaces/ICLFactory.sol";

contract Deploy is Script {
    HiroFactory public hiroFactory;

    address public weth = vm.envAddress("WETH");
    address public router = vm.envAddress("AERO_ROUTER");

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("./script/whitelist.json");

        address[] memory initialWhitelist = abi.decode(
            vm.parseJson(json),
            (address[])
        );

        // Build dynamic agents array by looking for AGENT_ADDRESS_1, AGENT_ADDRESS_2, etc.
        uint256 maxAgents = 5; // adjust as needed
        address[] memory agentsTemp = new address[](maxAgents);
        uint256 count = 0;
        for (uint256 i = 1; i <= maxAgents; i++) {
            string memory key = string(
                abi.encodePacked("AGENT_ADDRESS_", vm.toString(i))
            );
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

        vm.startBroadcast();

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );

        hiroFactory = new HiroFactory(
            30_000,
            msg.sender,
            initialWhitelist,
            agents
        );
        console.log("Hiro Factory deployed at:", address(hiroFactory));

        vm.stopBroadcast();
    }
}
