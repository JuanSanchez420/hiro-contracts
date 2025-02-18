// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {Hiro} from "../src/Hiro.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TestHiroFactory is Test {
     Hiro public hiro;
     HiroFactory public hiroFactory;
     HiroWallet public hiroWallet;
     uint256 public constant TOKEN_AMOUNT = 100 ether;

     receive () external payable {}

     function setUp() public {
          string memory json = vm.readFile("./script/whitelist.json");

          uint256 maxAgents = 5;
          address[] memory agentsTemp = new address[](maxAgents);
          uint256 count = 0;
          for (uint256 i = 1; i <= maxAgents; i++) {
                string memory key = string(abi.encodePacked("AGENT_ADDRESS_", vm.toString(i)));
                string memory agentStr = vm.envString(key);
                if (bytes(agentStr).length == 0) {
                     break;
                }
                agentsTemp[count] = vm.envAddress(key);
                count++;
          }
          address[] memory agents = new address[](count);
          for (uint256 i = 0; i < count; i++) {
                agents[i] = agentsTemp[i];
          }

          address[] memory initialWhitelist = abi.decode(vm.parseJson(json), (address[]));

          hiro = new Hiro();
          hiroFactory = new HiroFactory(
                address(hiro),
                TOKEN_AMOUNT,
                initialWhitelist,
                agents
          );
          // Approve factory to spend tokens
          IERC20(hiro).approve(address(hiroFactory), TOKEN_AMOUNT);
          hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet()));
     }

     function test_HiroFactory_details() public view {
          assertEq(hiroFactory.price(), TOKEN_AMOUNT);
          assertNotEq(address(hiroWallet), address(0));
     }

     function test_duplicateWalletCreation() public {
          vm.expectRevert("Subcontract already exists");
          hiroFactory.createHiroWallet();
     }

     function test_setPrice() public {
          uint256 newPrice = 50 ether;
          hiroFactory.setPrice(newPrice);
          assertEq(hiroFactory.price(), newPrice);
     }

     function test_nonOwnerSetPrice() public {
          address bob = address(0xBEEF);
          vm.startPrank(bob);
          vm.expectRevert();
          hiroFactory.setPrice(10 ether);
          vm.stopPrank();
     }

     function test_addRemoveWhitelist() public {
          address newAddr = address(0x1234);
          hiroFactory.addToWhitelist(newAddr);
          bool whitelisted = hiroFactory.isWhitelisted(newAddr);
          assertTrue(whitelisted);

          hiroFactory.removeFromWhitelist(newAddr);
          whitelisted = hiroFactory.isWhitelisted(newAddr);
          assertFalse(whitelisted);
     }

     function test_setAgentAndNonOwnerSetAgent() public {
          address agentAddr = address(0xABCD);
          // Set agent from owner
          hiroFactory.setAgent(agentAddr, true);
          bool isAgent = hiroFactory.isAgent(agentAddr);
          assertTrue(isAgent);

          // Attempt to change agent from non-owner
          address nonOwner = address(0xBEEF);
          vm.startPrank(nonOwner);
          vm.expectRevert();
          hiroFactory.setAgent(agentAddr, false);
          vm.stopPrank();
     }

     function test_tokenSweep() public {
          // After createHiroWallet, factory received TOKEN_AMOUNT tokens.
          uint256 factoryBalance = IERC20(hiro).balanceOf(address(hiroFactory));
          // Capture owner's token balance before sweep.
          uint256 ownerBalanceBefore = IERC20(hiro).balanceOf(address(this));
          hiroFactory.sweep(address(hiro), factoryBalance);
          uint256 ownerBalanceAfter = IERC20(hiro).balanceOf(address(this));
          assertEq(ownerBalanceAfter, ownerBalanceBefore + factoryBalance);
     }

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