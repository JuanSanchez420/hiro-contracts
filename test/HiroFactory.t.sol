// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {Hiro} from "../src/Hiro.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";


contract HiroFactoryTest is Test {
    Hiro public hiro;
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;

    function setUp() public {
        string memory json = vm.readFile("./script/whitelist.json");

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

        address[] memory initialWhitelist = abi.decode(
            vm.parseJson(json),
            (address[])
        );

        hiro = new Hiro();

        uint256 tokenAmount = 100 ether;

        hiroFactory = new HiroFactory(
            address(hiro),
            tokenAmount,
            initialWhitelist,
            agents
        );

        IERC20(hiro).approve(address(hiroFactory), tokenAmount);

        hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet()));
    }

    function test_HiroFactory_details() public view {
        assertEq(hiroFactory.price(), 100 ether);
        assertNotEq(address(hiroWallet), address(0));
    }
}