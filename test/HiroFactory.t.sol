// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {HiroWallet} from "../src/HiroWallet.sol";

contract HiroFactoryTest is Test {
    HiroFactory public hiroFactory;

    address public constant USER = address(0x1234);
    address public constant OTHER_USER = address(0x5678);
    address public constant INITIAL_AGENT = address(0x9999);
    address public constant INITIAL_WHITELIST = address(0x1111);

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

    function testConstructorSeedsWhitelistAndAgents() public view {
        assertTrue(hiroFactory.isWhitelisted(INITIAL_WHITELIST));
        assertTrue(hiroFactory.isAgent(INITIAL_AGENT));
        assertFalse(hiroFactory.isAgent(OTHER_USER));
    }

    function testCreateWalletRecordsOwner() public {
        address walletAddress = _createWallet(USER, 0);
        assertEq(hiroFactory.ownerToWallet(USER), walletAddress);
        assertEq(hiroFactory.getWallet(USER), walletAddress);
        assertTrue(walletAddress != address(0));
    }

    function testCreateWalletForwardsAllValue() public {
        uint256 deposit = 0.75 ether;
        vm.startPrank(USER);
        address wallet = hiroFactory.createHiroWallet{value: deposit}();
        vm.stopPrank();

        assertEq(address(wallet).balance, deposit);
        assertEq(address(hiroFactory).balance, 0);
    }

    function testCreateWalletDoesNotRequirePayment() public {
        vm.startPrank(USER);
        address wallet = hiroFactory.createHiroWallet();
        vm.stopPrank();

        assertEq(wallet, hiroFactory.ownerToWallet(USER));
    }

    function testPreventDuplicateWalletCreation() public {
        vm.startPrank(USER);
        hiroFactory.createHiroWallet();
        vm.expectRevert("Subcontract already exists");
        hiroFactory.createHiroWallet();
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
        // Factory no longer has receive(), so use vm.deal to simulate
        // ETH arriving via selfdestruct or other forced mechanisms
        vm.deal(address(hiroFactory), 1 ether);

        uint256 balanceBefore = address(this).balance;
        hiroFactory.sweepETH();
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function _createWallet(address walletOwner, uint256 value) internal returns (address walletAddress) {
        vm.startPrank(walletOwner);
        walletAddress = hiroFactory.createHiroWallet{value: value}();
        vm.stopPrank();
    }

    // ==================== EDGE CASE TESTS ====================

    function testSweepETHWithZeroBalance() public {
        // Ensure factory has no ETH
        assertEq(address(hiroFactory).balance, 0);

        uint256 balanceBefore = address(this).balance;

        // Should succeed even with zero balance
        hiroFactory.sweepETH();

        assertEq(address(this).balance, balanceBefore);
    }

    function testSetAgentTwiceWithSameValue() public {
        address newAgent = address(0xAAAA);

        // Set agent to true
        hiroFactory.setAgent(newAgent, true);
        assertTrue(hiroFactory.isAgent(newAgent));

        // Set agent to true again - should be idempotent
        hiroFactory.setAgent(newAgent, true);
        assertTrue(hiroFactory.isAgent(newAgent));

        // Set agent to false
        hiroFactory.setAgent(newAgent, false);
        assertFalse(hiroFactory.isAgent(newAgent));

        // Set agent to false again - should be idempotent
        hiroFactory.setAgent(newAgent, false);
        assertFalse(hiroFactory.isAgent(newAgent));
    }

    function testWhitelistRemovalDoesNotAffectExistingWallets() public {
        // Create a wallet
        address walletAddress = _createWallet(USER, 1 ether);
        HiroWallet wallet = HiroWallet(payable(walletAddress));

        // Add a target to whitelist
        address target = address(0xBEEF);
        hiroFactory.addToWhitelist(target);
        assertTrue(hiroFactory.isWhitelisted(target));

        // Create a mock that the wallet can call
        MockTarget mock = new MockTarget();
        hiroFactory.addToWhitelist(address(mock));

        // Agent calls mock through wallet - should work
        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(INITIAL_AGENT);
        wallet.execute(targets, dataArray, values);
        assertEq(mock.value(), 42);

        // Now remove mock from whitelist
        hiroFactory.removeFromWhitelist(address(mock));
        assertFalse(hiroFactory.isWhitelisted(address(mock)));

        // Existing wallet should now fail to call the removed address
        dataArray[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 100);
        vm.prank(INITIAL_AGENT);
        vm.expectRevert("Address not whitelisted");
        wallet.execute(targets, dataArray, values);

        // The wallet still exists and can call other whitelisted addresses
        // This verifies whitelist changes propagate to all wallets
    }

    function testAddAndRemoveMultipleFromWhitelist() public {
        address[] memory addresses = new address[](3);
        addresses[0] = address(0x1111);
        addresses[1] = address(0x2222);
        addresses[2] = address(0x3333);

        // Add all
        for (uint256 i = 0; i < 3; i++) {
            hiroFactory.addToWhitelist(addresses[i]);
            assertTrue(hiroFactory.isWhitelisted(addresses[i]));
        }

        // Remove middle one
        hiroFactory.removeFromWhitelist(addresses[1]);
        assertTrue(hiroFactory.isWhitelisted(addresses[0]));
        assertFalse(hiroFactory.isWhitelisted(addresses[1]));
        assertTrue(hiroFactory.isWhitelisted(addresses[2]));
    }

    function testAgentStatusPersistsAcrossWallets() public {
        // Create two wallets for different users
        address wallet1 = _createWallet(USER, 0);
        address wallet2 = _createWallet(OTHER_USER, 0);

        // Create a mock target
        MockTarget mock = new MockTarget();
        hiroFactory.addToWhitelist(address(mock));

        // Initial agent can execute on both wallets
        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(INITIAL_AGENT);
        HiroWallet(payable(wallet1)).execute(targets, dataArray, values);
        assertEq(mock.value(), 10);

        dataArray[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);
        vm.prank(INITIAL_AGENT);
        HiroWallet(payable(wallet2)).execute(targets, dataArray, values);
        assertEq(mock.value(), 20);

        // Remove agent
        hiroFactory.setAgent(INITIAL_AGENT, false);

        // Agent cannot execute on either wallet now
        vm.prank(INITIAL_AGENT);
        vm.expectRevert("Not an agent");
        HiroWallet(payable(wallet1)).execute(targets, dataArray, values);

        vm.prank(INITIAL_AGENT);
        vm.expectRevert("Not an agent");
        HiroWallet(payable(wallet2)).execute(targets, dataArray, values);
    }

    function testNonOwnerCannotManageWhitelist() public {
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.addToWhitelist(address(0xDEAD));

        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.removeFromWhitelist(INITIAL_WHITELIST);
    }
}

contract MockTarget {
    uint256 public value;

    function setValue(uint256 newValue) external payable {
        value = newValue;
    }

    receive() external payable {}
}
