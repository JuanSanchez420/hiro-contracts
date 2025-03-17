// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";
import "lib/slipstream/contracts/core/interfaces/ICLFactory.sol";

contract TestHiroFactory is Test {
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;
    uint256 public constant PURCHASE_PRICE = 10_000_000_000_000_000;

    address public weth = vm.envAddress("WETH");
    address public router = vm.envAddress("AERO_ROUTER");
    int24 startingTick = int24(vm.envInt("STARTING_TICK"));

    receive() external payable {}

    function setUp() public {
        uint256 forkId = vm.createFork("http://localhost:8545");
        vm.selectFork(forkId);

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

        hiroWallet = HiroWallet(
            payable(
                hiroFactory.createHiroWallet{
                    value: hiroFactory.purchasePrice() * 2
                }()
            )
        );
    }

    function test_HiroFactory_details() public view {
        assertEq(hiroFactory.purchasePrice(), PURCHASE_PRICE);
        assertNotEq(address(hiroWallet), address(0));
    }

    function test_duplicateWalletCreation() public {
        vm.expectRevert("Subcontract already exists");
        hiroFactory.createHiroWallet();
    }

    function test_setPrice() public {
        vm.startPrank(msg.sender);
        uint256 newPrice = 50 ether;
        hiroFactory.setTransactionPrice(newPrice);
        assertEq(hiroFactory.transactionPrice(), newPrice);
        vm.stopPrank();
    }

    function test_nonOwnerSetPrice() public {
        address bob = address(0xBEEF);
        vm.startPrank(bob);
        vm.expectRevert();
        hiroFactory.setTransactionPrice(10 ether);
        vm.stopPrank();
    }

    function test_addRemoveWhitelist() public {
        vm.startPrank(msg.sender);
        address newAddr = address(0x1234);
        hiroFactory.addToWhitelist(newAddr);
        bool whitelisted = hiroFactory.isWhitelisted(newAddr);
        assertTrue(whitelisted);

        hiroFactory.removeFromWhitelist(newAddr);
        whitelisted = hiroFactory.isWhitelisted(newAddr);
        assertFalse(whitelisted);
        vm.stopPrank();
    }

    function test_setAgentAndNonOwnerSetAgent() public {
        vm.startPrank(msg.sender);
        address agentAddr = address(0xABCD);
        // Set agent from owner
        hiroFactory.setAgent(agentAddr, true);
        bool isAgent = hiroFactory.isAgent(agentAddr);
        assertTrue(isAgent);
        vm.stopPrank();

        // Attempt to change agent from non-owner
        address nonOwner = address(0xBEEF);
        vm.startPrank(nonOwner);
        vm.expectRevert();
        hiroFactory.setAgent(agentAddr, false);
        vm.stopPrank();
    }

    /*
    function test_tokenSweep() public {
        vm.startPrank(msg.sender);
        // After createHiroWallet, factory received TOKEN_AMOUNT ETH.
        uint256 factoryBalance = address(hiroFactory).balance;
        // Capture owner's token balance before sweep.
        uint256 ownerBalanceBefore = address(msg.sender).balance;
        hiroFactory.sweep(address(hiro), factoryBalance);
        uint256 ownerBalanceAfter = IERC20(hiro).balanceOf(msg.sender);
        assertEq(ownerBalanceAfter, ownerBalanceBefore + factoryBalance);
        vm.stopPrank();
    }
    */
    /*

    /* tested, works, but don't want public receive() on factory
     function test_sweepETH() public {
          // Send 1 ether to the factory contract.
          (bool success, ) = address(hiroFactory).call{value: 1 ether}("");
          require(success, "ETH transfer failed");

          uint256 ownerBalanceBefore = address(this).balance;
          hiroFactory.sweepETH();
          uint256 ownerBalanceAfter = address(this).balance;
          console.log(ownerBalanceBefore, ownerBalanceAfter);
          assertEq(ownerBalanceAfter, ownerBalanceBefore + 1 ether);
     }
     */
}
