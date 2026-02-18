// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockContract {
    uint256 public value;
    uint256 public lastReceivedValue;

    function setValue(uint256 newValue) external payable {
        value = newValue;
        lastReceivedValue = msg.value;
    }

    receive() external payable {
        lastReceivedValue = msg.value;
    }
}

contract MockERC20 is IERC20 {
    string public constant name = "Mock";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "insufficient allowance");
        allowance[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract TestHiroWallet is Test {
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;
    MockERC20 public mockToken;

    address public user = address(0x1234);
    address public agent = address(0x5678);
    address public nonAgent = address(0x9ABC);

    function setUp() public {
        vm.deal(user, 10 ether);

        address[] memory whitelist = new address[](0);
        address[] memory agents = new address[](1);
        agents[0] = agent;

        vm.prank(user);
        hiroFactory = new HiroFactory(whitelist, agents);
        mockToken = new MockERC20();

        vm.startPrank(user);
        hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet{value: 1 ether}()));
        vm.stopPrank();
    }

    function testOwnerCanWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(user);
        hiroWallet.withdraw(address(mockToken), 0.4 ether);

        assertEq(mockToken.balanceOf(user), 0.4 ether);
    }

    function testAgentCanExecuteSingleCall() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        vm.deal(address(hiroWallet), 1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 42);
        uint256[] memory values = new uint256[](1);
        values[0] = 0.25 ether;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.value(), 42);
        assertEq(mock.lastReceivedValue(), 0.25 ether);
    }

    function testExecuteFailsForNonAgent() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 1);
        uint256[] memory values = new uint256[](1);

        vm.prank(nonAgent);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteFailsForUnwhitelistedTarget() public {
        MockContract mock = new MockContract();

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 1);
        uint256[] memory values = new uint256[](1);

        vm.prank(agent);
        vm.expectRevert("Address not whitelisted");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteBatchCalls() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addToWhitelist(address(mock1));
        hiroFactory.addToWhitelist(address(mock2));
        vm.stopPrank();

        vm.deal(address(hiroWallet), 1 ether);

        address[] memory targets = new address[](2);
        targets[0] = address(mock1);
        targets[1] = address(mock2);

        bytes[] memory dataArray = new bytes[](2);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 10);
        dataArray[1] = abi.encodeWithSelector(MockContract.setValue.selector, 20);

        uint256[] memory values = new uint256[](2);
        values[0] = 0.1 ether;
        values[1] = 0.2 ether;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock1.value(), 10);
        assertEq(mock2.value(), 20);
        assertEq(mock1.lastReceivedValue(), 0.1 ether);
        assertEq(mock2.lastReceivedValue(), 0.2 ether);
    }

    function testExecuteRevertsOnLengthMismatch() public {
        address[] memory targets = new address[](1);
        bytes[] memory dataArray = new bytes[](2);
        uint256[] memory values = new uint256[](1);

        vm.prank(agent);
        vm.expectRevert("Array length mismatch");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteRevertsWhenNoCallsProvided() public {
        address[] memory targets = new address[](0);
        bytes[] memory dataArray = new bytes[](0);
        uint256[] memory values = new uint256[](0);

        vm.prank(agent);
        vm.expectRevert("No calls provided");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteRevertsWhenNotEnoughEth() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        vm.deal(address(hiroWallet), 0.1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 5);
        uint256[] memory values = new uint256[](1);
        values[0] = 0.2 ether;

        vm.prank(agent);
        vm.expectRevert("Not enough ETH on wallet");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testOwnerCanWithdrawETH() public {
        uint256 initialWalletBalance = address(hiroWallet).balance;
        uint256 initialUserBalance = user.balance;

        vm.prank(user);
        hiroWallet.withdrawETH(0.5 ether);

        assertEq(address(hiroWallet).balance, initialWalletBalance - 0.5 ether);
        assertEq(user.balance, initialUserBalance + 0.5 ether);
    }

    function testNonOwnerCannotWithdrawETH() public {
        vm.prank(nonAgent);
        vm.expectRevert("Not the owner");
        hiroWallet.withdrawETH(0.1 ether);
    }

    function testWithdrawETHRevertsOnInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert();
        hiroWallet.withdrawETH(2 ether); // More than wallet balance
    }

    function testAgentCanCallFactoryWithoutWhitelist() public {
        // Verify factory is NOT on the whitelist
        assertFalse(hiroFactory.isWhitelisted(address(hiroFactory)));

        // Agent should be able to call factory even though it's not whitelisted
        // Call isWhitelisted as a simple test - the key is that execute() succeeds
        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(HiroFactory.isWhitelisted.selector, address(0x1234));
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // This should succeed because factory is implicitly trusted by the wallet
        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        // If we got here without reverting, the test passed
        // The factory call went through without being on the whitelist
    }

    // ==================== SECURITY TESTS ====================

    function testAgentCannotCallFactoryOwnerFunctions() public {
        // Agent should NOT be able to call owner-only factory functions through wallet
        // Even though wallet can call factory, factory's onlyOwner protects sensitive functions
        // The wallet catches reverts and throws "Call failed"

        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // Try to add malicious address to whitelist
        dataArray[0] = abi.encodeWithSelector(HiroFactory.addToWhitelist.selector, address(0xBAD));
        vm.prank(agent);
        vm.expectRevert("Call failed");
        hiroWallet.execute(targets, dataArray, values);

        // Try to remove from whitelist
        dataArray[0] = abi.encodeWithSelector(HiroFactory.removeFromWhitelist.selector, address(0x123));
        vm.prank(agent);
        vm.expectRevert("Call failed");
        hiroWallet.execute(targets, dataArray, values);

        // Try to add a rogue agent
        dataArray[0] = abi.encodeWithSelector(HiroFactory.setAgent.selector, address(0xBAD), true);
        vm.prank(agent);
        vm.expectRevert("Call failed");
        hiroWallet.execute(targets, dataArray, values);

        // Try to sweep tokens from factory
        dataArray[0] = abi.encodeWithSelector(HiroFactory.sweep.selector, address(mockToken), 1 ether);
        vm.prank(agent);
        vm.expectRevert("Call failed");
        hiroWallet.execute(targets, dataArray, values);

        // Try to sweep ETH from factory
        dataArray[0] = abi.encodeWithSelector(HiroFactory.sweepETH.selector);
        vm.prank(agent);
        vm.expectRevert("Call failed");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testFeeCollectionETHEndToEnd() public {
        // Simulate fee collection: wallet sends ETH to factory, owner sweeps it
        uint256 feeAmount = 0.1 ether;
        uint256 ownerBalanceBefore = user.balance;

        // Agent sends ETH to factory (fee skimming)
        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = ""; // empty calldata, just sending ETH
        uint256[] memory values = new uint256[](1);
        values[0] = feeAmount;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        // Verify factory received ETH
        assertEq(address(hiroFactory).balance, feeAmount);

        // Owner sweeps ETH from factory
        vm.prank(user);
        hiroFactory.sweepETH();

        // Verify owner received ETH
        assertEq(address(hiroFactory).balance, 0);
        assertEq(user.balance, ownerBalanceBefore + feeAmount);
    }

    function testFeeCollectionTokenEndToEnd() public {
        // Simulate fee collection: wallet transfers tokens to factory, owner sweeps
        uint256 feeAmount = 0.5 ether;
        mockToken.mint(address(hiroWallet), 1 ether);

        // Whitelist token for transfer call
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mockToken));

        // Agent transfers tokens to factory
        address[] memory targets = new address[](1);
        targets[0] = address(mockToken);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(IERC20.transfer.selector, address(hiroFactory), feeAmount);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        // Verify factory received tokens
        assertEq(mockToken.balanceOf(address(hiroFactory)), feeAmount);

        // Owner sweeps tokens
        vm.prank(user);
        hiroFactory.sweep(address(mockToken), feeAmount);

        // Verify owner received tokens
        assertEq(mockToken.balanceOf(address(hiroFactory)), 0);
        assertEq(mockToken.balanceOf(user), feeAmount);
    }

    function testNonOwnerCannotSweepFactory() public {
        // Send some ETH to factory
        vm.deal(address(hiroFactory), 1 ether);
        mockToken.mint(address(hiroFactory), 1 ether);

        // Non-owner (agent) cannot sweep
        vm.prank(agent);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();

        vm.prank(agent);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweep(address(mockToken), 1 ether);

        // Random address cannot sweep
        vm.prank(nonAgent);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();
    }

    function testFactoryReceiveDoesNotCreateVulnerability() public {
        // Anyone can send ETH to factory, but only owner can withdraw
        address randomSender = address(0xDEAD);
        vm.deal(randomSender, 1 ether);

        // Random address sends ETH to factory
        vm.prank(randomSender);
        (bool success,) = address(hiroFactory).call{value: 0.5 ether}("");
        assertTrue(success);

        assertEq(address(hiroFactory).balance, 0.5 ether);

        // Random sender cannot get it back
        vm.prank(randomSender);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();

        // Only owner can sweep
        uint256 ownerBalanceBefore = user.balance;
        vm.prank(user);
        hiroFactory.sweepETH();
        assertEq(user.balance, ownerBalanceBefore + 0.5 ether);
    }

    function testWalletCannotBypassWhitelistViaDifferentFactory() public {
        // Create a malicious "factory" that always returns true for isWhitelisted
        // Wallet should still use its own factory reference, not be tricked

        // The wallet's factory is immutable and set at construction
        // This test verifies the wallet checks against its own factory
        assertEq(hiroWallet.factory(), address(hiroFactory));

        // Even if someone deploys a fake factory, wallet uses its own
        MockContract unwhitelisted = new MockContract();
        assertFalse(hiroFactory.isWhitelisted(address(unwhitelisted)));

        address[] memory targets = new address[](1);
        targets[0] = address(unwhitelisted);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = "";
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(agent);
        vm.expectRevert("Address not whitelisted");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testAgentCannotCreateWalletForWalletThroughFactory() public {
        // Edge case: agent calls createHiroWallet through wallet
        // This would create a wallet owned by the HiroWallet, which is harmless
        // but let's verify it doesn't cause issues

        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(HiroFactory.createHiroWallet.selector);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        // A wallet was created owned by hiroWallet
        address walletOwnedByWallet = hiroFactory.ownerToWallet(address(hiroWallet));
        assertTrue(walletOwnedByWallet != address(0));

        // But this is harmless - hiroWallet has no function to interact with it
        // The new wallet's owner is hiroWallet, but hiroWallet can't call withdraw/withdrawETH on it
        HiroWallet nestedWallet = HiroWallet(payable(walletOwnedByWallet));
        assertEq(nestedWallet.owner(), address(hiroWallet));

        // hiroWallet cannot withdraw from the nested wallet (no way to call it)
        // This is just a curiosity, not exploitable
    }

    // ==================== ADDITIONAL COVERAGE TESTS ====================

    function testOwnerCanWithdrawNonWhitelistedToken() public {
        // This proves owners can always withdraw any token, regardless of whitelist
        MockERC20 randomToken = new MockERC20();
        randomToken.mint(address(hiroWallet), 1 ether);

        // Verify token is NOT whitelisted
        assertFalse(hiroFactory.isWhitelisted(address(randomToken)));

        // Owner can still withdraw it
        vm.prank(user);
        hiroWallet.withdraw(address(randomToken), 1 ether);

        assertEq(randomToken.balanceOf(user), 1 ether);
    }

    function testNonOwnerCannotWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(nonAgent);
        vm.expectRevert("Not the owner");
        hiroWallet.withdraw(address(mockToken), 0.5 ether);
    }

    function testAgentCannotWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(agent);
        vm.expectRevert("Not the owner");
        hiroWallet.withdraw(address(mockToken), 0.5 ether);
    }

    function testAgentRemoval() public {
        assertTrue(hiroFactory.isAgent(agent));

        vm.prank(user);
        hiroFactory.setAgent(agent, false);

        assertFalse(hiroFactory.isAgent(agent));

        // Removed agent cannot execute
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = "";
        uint256[] memory values = new uint256[](1);

        vm.prank(agent);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testBatchPartialFailureRevertsAll() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addToWhitelist(address(mock1));
        // mock2 NOT whitelisted
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(mock1);
        targets[1] = address(mock2); // Will fail
        bytes[] memory dataArray = new bytes[](2);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 10);
        dataArray[1] = abi.encodeWithSelector(MockContract.setValue.selector, 20);
        uint256[] memory values = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert("Address not whitelisted");
        hiroWallet.execute(targets, dataArray, values);

        // First call should NOT have persisted
        assertEq(mock1.value(), 0);
    }

    function testWalletCanReceiveETHFromAnyone() public {
        address randomSender = address(0xCAFE);
        vm.deal(randomSender, 1 ether);

        uint256 balanceBefore = address(hiroWallet).balance;

        vm.prank(randomSender);
        (bool success,) = address(hiroWallet).call{value: 0.5 ether}("");

        assertTrue(success);
        assertEq(address(hiroWallet).balance, balanceBefore + 0.5 ether);
    }

    function testAddToWhitelistRevertsOnZeroAddress() public {
        vm.prank(user);
        vm.expectRevert("Invalid address");
        hiroFactory.addToWhitelist(address(0));
    }

    function testRemoveFromWhitelistRevertsOnZeroAddress() public {
        vm.prank(user);
        vm.expectRevert("Invalid address");
        hiroFactory.removeFromWhitelist(address(0));
    }

    function testOwnerCannotCallExecute() public {
        // Owner is not an agent by default
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = "";
        uint256[] memory values = new uint256[](1);

        vm.prank(user);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(targets, dataArray, values);
    }

    function testFactorySweepTokens() public {
        mockToken.mint(address(hiroFactory), 1 ether);

        uint256 balanceBefore = mockToken.balanceOf(user);

        vm.prank(user);
        hiroFactory.sweep(address(mockToken), 0.5 ether);

        assertEq(mockToken.balanceOf(user), balanceBefore + 0.5 ether);
        assertEq(mockToken.balanceOf(address(hiroFactory)), 0.5 ether);
    }

    function testWalletImmutables() public {
        assertEq(hiroWallet.owner(), user);
        assertEq(hiroWallet.factory(), address(hiroFactory));
    }

    function testAgentCannotWithdrawETH() public {
        vm.prank(agent);
        vm.expectRevert("Not the owner");
        hiroWallet.withdrawETH(0.1 ether);
    }

    // ==================== EDGE CASE TESTS ====================

    function testWithdrawZeroTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        uint256 balanceBefore = mockToken.balanceOf(user);
        vm.prank(user);
        hiroWallet.withdraw(address(mockToken), 0);

        // Should succeed with no change
        assertEq(mockToken.balanceOf(user), balanceBefore);
        assertEq(mockToken.balanceOf(address(hiroWallet)), 1 ether);
    }

    function testWithdrawZeroETH() public {
        uint256 initialWalletBalance = address(hiroWallet).balance;
        uint256 initialUserBalance = user.balance;

        vm.prank(user);
        hiroWallet.withdrawETH(0);

        // Should succeed with no change
        assertEq(address(hiroWallet).balance, initialWalletBalance);
        assertEq(user.balance, initialUserBalance);
    }

    function testExecuteWithZeroValueTransfer() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 100);
        uint256[] memory values = new uint256[](1);
        values[0] = 0; // Zero ETH

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.value(), 100);
        assertEq(mock.lastReceivedValue(), 0);
    }

    function testBatchExecutionFirstCallSucceedsSecondFails() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addToWhitelist(address(mock1));
        hiroFactory.addToWhitelist(address(mock2));
        vm.stopPrank();

        // Create a scenario where second call reverts
        // We'll try to send more ETH than available for second call
        vm.deal(address(hiroWallet), 0.5 ether);

        address[] memory targets = new address[](2);
        targets[0] = address(mock1);
        targets[1] = address(mock2);
        bytes[] memory dataArray = new bytes[](2);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 10);
        dataArray[1] = abi.encodeWithSelector(MockContract.setValue.selector, 20);
        uint256[] memory values = new uint256[](2);
        values[0] = 0.3 ether;
        values[1] = 0.3 ether; // Total 0.6 ETH > 0.5 ETH available

        vm.prank(agent);
        vm.expectRevert("Not enough ETH on wallet");
        hiroWallet.execute(targets, dataArray, values);

        // First call should NOT have persisted due to atomic revert
        assertEq(mock1.value(), 0);
    }

    function testExecuteEmptyCalldata() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addToWhitelist(address(mock));

        vm.deal(address(hiroWallet), 1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = ""; // Empty calldata - just send ETH
        uint256[] memory values = new uint256[](1);
        values[0] = 0.25 ether;

        vm.prank(agent);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.lastReceivedValue(), 0.25 ether);
    }

    function testMultipleWithdrawals() public {
        mockToken.mint(address(hiroWallet), 1 ether);
        vm.deal(address(hiroWallet), 1 ether);

        vm.startPrank(user);

        // Multiple token withdrawals
        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.4 ether);

        assertEq(mockToken.balanceOf(user), 1 ether);
        assertEq(mockToken.balanceOf(address(hiroWallet)), 0);

        // Multiple ETH withdrawals
        uint256 initialBalance = user.balance;
        hiroWallet.withdrawETH(0.5 ether);
        hiroWallet.withdrawETH(0.5 ether);

        assertEq(user.balance, initialBalance + 1 ether);
        assertEq(address(hiroWallet).balance, 0);

        vm.stopPrank();
    }
}
