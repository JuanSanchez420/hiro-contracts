// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {IHiroWallet} from "../src/interfaces/IHiroWallet.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {NoopStrategy} from "./mocks/NoopStrategy.sol";

contract HiroFactoryTest is Test {
    HiroFactory public hiroFactory;

    address public constant USER = address(0x1234);
    address public constant OTHER_USER = address(0x5678);
    address public constant INITIAL_TARGET = address(0x1111);

    event PausedSet(bool paused);
    event TargetAdded(address indexed target);
    event TargetRemoved(address indexed target);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);

    receive() external payable {}

    function setUp() public {
        address[] memory initialTargets = new address[](1);
        initialTargets[0] = INITIAL_TARGET;

        hiroFactory = new HiroFactory(initialTargets);

        vm.deal(USER, 5 ether);
        vm.deal(OTHER_USER, 5 ether);
        vm.deal(address(this), 5 ether);
    }

    function testConstructorSeedsTargets() public view {
        assertTrue(hiroFactory.targetWhitelist(INITIAL_TARGET));
        assertFalse(hiroFactory.targetWhitelist(OTHER_USER));
        assertFalse(hiroFactory.paused());
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
        vm.expectRevert(HiroFactory.SubcontractExists.selector);
        hiroFactory.createHiroWallet();
        vm.stopPrank();
    }

    function testTargetWhitelistManagement() public {
        address newTarget = address(0xBEEF);

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit TargetAdded(newTarget);
        hiroFactory.addTarget(newTarget);
        assertTrue(hiroFactory.targetWhitelist(newTarget));

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit TargetRemoved(newTarget);
        hiroFactory.removeTarget(newTarget);
        assertFalse(hiroFactory.targetWhitelist(newTarget));
    }

    function testAddRemoveTargetRejectZeroAddress() public {
        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.addTarget(address(0));

        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.removeTarget(address(0));
    }

    function testOwnerCanSweepEth() public {
        vm.deal(address(hiroFactory), 1 ether);

        uint256 balanceBefore = address(this).balance;
        hiroFactory.sweepETH();
        assertEq(address(this).balance, balanceBefore + 1 ether);
    }

    function testSweepETHWithZeroBalance() public {
        assertEq(address(hiroFactory).balance, 0);

        uint256 balanceBefore = address(this).balance;
        hiroFactory.sweepETH();
        assertEq(address(this).balance, balanceBefore);
    }

    function testWhitelistRemovalAffectsExistingWallets() public {
        address walletAddress = _createWallet(USER, 1 ether);
        HiroWallet wallet = HiroWallet(payable(walletAddress));

        MockTarget mock = new MockTarget();
        hiroFactory.addTarget(address(mock));

        IHiroWallet.Call[] memory calls = new IHiroWallet.Call[](1);
        calls[0] = IHiroWallet.Call({
            target: address(mock),
            data: abi.encodeWithSelector(MockTarget.setValue.selector, 42),
            value: 0
        });

        vm.prank(USER);
        wallet.executeAsOwner(calls);
        assertEq(mock.value(), 42);

        hiroFactory.removeTarget(address(mock));
        assertFalse(hiroFactory.targetWhitelist(address(mock)));

        calls[0].data = abi.encodeWithSelector(MockTarget.setValue.selector, 100);
        vm.prank(USER);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        wallet.executeAsOwner(calls);
    }

    function testAddAndRemoveMultipleFromWhitelist() public {
        address[] memory addresses = new address[](3);
        addresses[0] = address(0x1111);
        addresses[1] = address(0x2222);
        addresses[2] = address(0x3333);

        for (uint256 i = 0; i < 3; i++) {
            hiroFactory.addTarget(addresses[i]);
            assertTrue(hiroFactory.targetWhitelist(addresses[i]));
        }

        hiroFactory.removeTarget(addresses[1]);
        assertTrue(hiroFactory.targetWhitelist(addresses[0]));
        assertFalse(hiroFactory.targetWhitelist(addresses[1]));
        assertTrue(hiroFactory.targetWhitelist(addresses[2]));
    }

    function testPredictWalletAddress() public {
        address predicted = hiroFactory.predictWalletAddress(USER);
        address actual = _createWallet(USER, 0);
        assertEq(predicted, actual);
    }

    function testPredictWalletAddressMultipleUsers() public {
        address predictedUser = hiroFactory.predictWalletAddress(USER);
        address predictedOther = hiroFactory.predictWalletAddress(OTHER_USER);
        assertTrue(predictedUser != predictedOther);

        address actualUser = _createWallet(USER, 0);
        address actualOther = _createWallet(OTHER_USER, 0);
        assertEq(predictedUser, actualUser);
        assertEq(predictedOther, actualOther);
    }

    function testCreateWalletStillWorks() public {
        vm.startPrank(USER);
        address payable wallet = hiroFactory.createHiroWallet{value: 1 ether}();
        vm.stopPrank();

        assertEq(hiroFactory.ownerToWallet(USER), wallet);
        assertEq(hiroFactory.getWallet(USER), wallet);
        assertTrue(wallet != address(0));
        assertEq(address(wallet).balance, 1 ether);

        HiroWallet w = HiroWallet(wallet);
        assertEq(w.owner(), USER);
        assertEq(w.factory(), address(hiroFactory));
    }

    function testNonOwnerCannotManageWhitelist() public {
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.addTarget(address(0xDEAD));

        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.removeTarget(INITIAL_TARGET);
    }

    // ==================== validateCall TESTS ====================

    function testValidateCall_whitelistedTarget_succeeds() public view {
        hiroFactory.validateCall(INITIAL_TARGET);
    }

    function testValidateCall_selfCall_alwaysAllowed() public view {
        hiroFactory.validateCall(address(hiroFactory));
    }

    function testValidateCall_notWhitelisted_reverts() public {
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroFactory.validateCall(address(0xDEAD));
    }

    function testValidateCall_paused_reverts() public {
        hiroFactory.pause();
        vm.expectRevert(HiroFactory.Paused.selector);
        hiroFactory.validateCall(INITIAL_TARGET);
    }

    function testValidateCall_pausedTakesPrecedenceOverSelfCall() public {
        hiroFactory.pause();
        vm.expectRevert(HiroFactory.Paused.selector);
        hiroFactory.validateCall(address(hiroFactory));
    }

    // ==================== pause / unpause TESTS ====================

    function testPause_emitsAndSetsFlag() public {
        vm.expectEmit(false, false, false, true, address(hiroFactory));
        emit PausedSet(true);
        hiroFactory.pause();
        assertTrue(hiroFactory.paused());
    }

    function testUnpause_emitsAndClearsFlag() public {
        hiroFactory.pause();
        assertTrue(hiroFactory.paused());

        vm.expectEmit(false, false, false, true, address(hiroFactory));
        emit PausedSet(false);
        hiroFactory.unpause();
        assertFalse(hiroFactory.paused());
    }

    function testPause_isIdempotent() public {
        hiroFactory.pause();
        hiroFactory.pause();
        assertTrue(hiroFactory.paused());
    }

    function testUnpause_isIdempotent() public {
        hiroFactory.unpause();
        assertFalse(hiroFactory.paused());
    }

    function testPause_onlyOwner() public {
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.pause();
    }

    function testUnpause_onlyOwner() public {
        hiroFactory.pause();
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.unpause();
    }

    function _createWallet(address walletOwner, uint256 value) internal returns (address walletAddress) {
        vm.startPrank(walletOwner);
        walletAddress = hiroFactory.createHiroWallet{value: value}();
        vm.stopPrank();
    }

    // ==================== agentWhitelist TESTS ====================

    function testAgentWhitelistManagement() public {
        address agent = address(0xA1);

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit AgentAdded(agent);
        hiroFactory.addAgent(agent);
        assertTrue(hiroFactory.agentWhitelist(agent));

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit AgentRemoved(agent);
        hiroFactory.removeAgent(agent);
        assertFalse(hiroFactory.agentWhitelist(agent));
    }

    function testAddRemoveAgentRejectZeroAddress() public {
        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.addAgent(address(0));

        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.removeAgent(address(0));
    }

    function testNonOwnerCannotManageAgents() public {
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.addAgent(address(0xA1));

        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.removeAgent(address(0xA1));
    }

    function testAddAgent_idempotentReAdd() public {
        hiroFactory.addAgent(address(0xA1));
        hiroFactory.addAgent(address(0xA1));
        assertTrue(hiroFactory.agentWhitelist(address(0xA1)));
    }

    function testRemoveAgent_idempotentNoop() public {
        hiroFactory.removeAgent(address(0xA1));
        assertFalse(hiroFactory.agentWhitelist(address(0xA1)));
    }

    // ==================== strategyWhitelist TESTS ====================

    function testStrategyWhitelistManagement() public {
        address strat = address(new NoopStrategy());

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit StrategyAdded(strat);
        hiroFactory.addStrategy(strat);
        assertTrue(hiroFactory.strategyWhitelist(strat));

        vm.expectEmit(true, false, false, true, address(hiroFactory));
        emit StrategyRemoved(strat);
        hiroFactory.removeStrategy(strat);
        assertFalse(hiroFactory.strategyWhitelist(strat));
    }

    function testAddRemoveStrategyRejectZeroAddress() public {
        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.addStrategy(address(0));

        vm.expectRevert(HiroFactory.InvalidAddress.selector);
        hiroFactory.removeStrategy(address(0));
    }

    function testNonOwnerCannotManageStrategies() public {
        address strat = address(new NoopStrategy());
        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.addStrategy(strat);

        vm.prank(OTHER_USER);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.removeStrategy(strat);
    }

    function testAddStrategy_idempotentReAdd() public {
        address strat = address(new NoopStrategy());
        hiroFactory.addStrategy(strat);
        hiroFactory.addStrategy(strat);
        assertTrue(hiroFactory.strategyWhitelist(strat));
    }

    function testRemoveStrategy_idempotentNoop() public {
        address strat = address(new NoopStrategy());
        hiroFactory.removeStrategy(strat);
        assertFalse(hiroFactory.strategyWhitelist(strat));
    }
}

contract MockTarget {
    uint256 public value;

    function setValue(uint256 newValue) external payable {
        value = newValue;
    }

    receive() external payable {}
}
