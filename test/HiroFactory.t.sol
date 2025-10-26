// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {HiroFactory} from "../src/HiroFactory.sol";

contract HiroFactoryTest is Test {
    HiroFactory public hiroFactory;

    address public constant USER = address(0x1234);
    address public constant OTHER_USER = address(0x5678);
    address public constant INITIAL_AGENT = address(0x9999);
    address public constant INITIAL_WHITELIST = address(0x1111);

    uint256 public constant PURCHASE_PRICE = 10_000_000_000_000_000;

    receive() external payable {}

    function setUp() public {
        address[] memory whitelist = new address[](1);
        whitelist[0] = INITIAL_WHITELIST;

        address[] memory agents = new address[](1);
        agents[0] = INITIAL_AGENT;

        hiroFactory = new HiroFactory(address(this), whitelist, agents);

        vm.deal(USER, 5 ether);
        vm.deal(OTHER_USER, 5 ether);
        vm.deal(address(this), 5 ether);
    }

    function testPurchasePriceIsConstant() public view {
        assertEq(hiroFactory.purchasePrice(), PURCHASE_PRICE);
    }

    function testConstructorSeedsWhitelistAndAgents() public view {
        assertTrue(hiroFactory.isWhitelisted(INITIAL_WHITELIST));
        assertTrue(hiroFactory.isAgent(INITIAL_AGENT));
        assertFalse(hiroFactory.isAgent(OTHER_USER));
    }

    function testCreateWalletRecordsOwner() public {
        address walletAddress = _createWallet(USER);
        assertEq(hiroFactory.ownerToWallet(USER), walletAddress);
        assertEq(hiroFactory.getWallet(USER), walletAddress);
        assertTrue(walletAddress != address(0));
    }

    function testCreateWalletRequiresPurchasePrice() public {
        vm.startPrank(USER);
        vm.expectRevert("Insufficient funds");
        hiroFactory.createHiroWallet{value: PURCHASE_PRICE - 1}();
        vm.stopPrank();
    }

    function testPreventDuplicateWalletCreation() public {
        vm.startPrank(USER);
        hiroFactory.createHiroWallet{value: PURCHASE_PRICE}();
        vm.expectRevert("Subcontract already exists");
        hiroFactory.createHiroWallet{value: PURCHASE_PRICE}();
        vm.stopPrank();
    }

    function testWhitelistManagement() public {
        address newTarget = address(0xBEEF);
        hiroFactory.addToWhitelist(newTarget);
        assertTrue(hiroFactory.isWhitelisted(newTarget));

        hiroFactory.removeFromWhitelist(newTarget);
        assertFalse(hiroFactory.isWhitelisted(newTarget));
    }

    function testAgentManagementRequiresOwnership() public {
        address newAgent = address(0xAAAA);
        hiroFactory.setAgent(newAgent, true);
        assertTrue(hiroFactory.isAgent(newAgent));

        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.setAgent(newAgent, false);
    }

    function testOwnerCanSweepEth() public {
        (bool sent, ) = address(hiroFactory).call{value: 1 ether}("");
        require(sent, "fund factory");

        uint256 balanceBefore = address(this).balance;
        hiroFactory.sweepETH();
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function _createWallet(address walletOwner) internal returns (address walletAddress) {
        vm.startPrank(walletOwner);
        walletAddress = hiroFactory.createHiroWallet{value: PURCHASE_PRICE}();
        vm.stopPrank();
    }
}
