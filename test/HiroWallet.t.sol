// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;
 
import "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {Hiro} from "../src/Hiro.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 
interface IHiroFactory {
    function isWhitelisted(address) external view returns (bool);
    function isAgent(address) external view returns (bool);
}
 
// Dummy target contract to be used with execute()
contract DummyTarget {
    uint256 public value;
 
    function doSomething() external returns (uint256) {
        value = 42;
        return value;
    }
}
 
contract HiroWalletTestExtended is Test {
    Hiro public hiro;
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;
    address public owner;
    address public notOwner;
    address public agent;
 
    uint256 constant TOKEN_AMOUNT = 1000 * 1e18; // Adjust as required
 
    receive () external payable {}

    function setUp() public {
        owner = address(this);
        notOwner = address(0xBEEF);
        // For testing, set agent to a known address. In a real setup, agents array comes from env vars.
        agent = address(0xABCD);
 
        // Prepare a fake whitelist json: for simplicity, whitelist this test contract.
        string memory json = "[\"0x0000000000000000000000000000000000000001\"]";
 
        uint256 maxAgents = 5;
        address[] memory agentsTemp = new address[](maxAgents);
        uint256 count = 0;
        // We'll simulate one agent.
        agentsTemp[count] = agent;
        count++;
        address[] memory agents = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            agents[i] = agentsTemp[i];
        }
 
        // Decode initialWhitelist from json.
        address[] memory initialWhitelist = abi.decode(vm.parseJson(json), (address[]));
 
        hiro = new Hiro();
        hiroFactory = new HiroFactory(
            address(hiro),
            TOKEN_AMOUNT,
            msg.sender,
            initialWhitelist,
            agents
        );
        // Approve factory to spend tokens on behalf of owner.
        IERC20(address(hiro)).approve(address(hiroFactory), TOKEN_AMOUNT);
        hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet()));
 
        // Fund the owner with tokens for deposit tests.
        // Assuming Hiro token mints tokens to deployer in its constructor.
        // If not, adjust token minting accordingly.
    }
 
    // Test deposit: only owner can deposit tokens.
    function testDepositSuccess() public {
        uint256 depositAmount = 100 * 1e18;
 
        // Simulate owner approving hirowallet to pull tokens.
        IERC20 token = IERC20(address(hiro));
        uint256 ownerBalanceBefore = token.balanceOf(owner);
 
        // As owner, deposit tokens from owner to hirowallet.
        // Approve hirowallet to pull tokens.
        token.approve(address(hiroWallet), depositAmount);
        hiroWallet.deposit(address(hiro), depositAmount);
 
        uint256 contractBalance = token.balanceOf(address(hiroWallet));
        assertEq(contractBalance, depositAmount);
 
        // Owner balance should reduce accordingly.
        uint256 ownerBalanceAfter = token.balanceOf(owner);
        assertEq(ownerBalanceBefore - ownerBalanceAfter, depositAmount);
    }
 
    function testDepositFailNotOwner() public {
        uint256 depositAmount = 100 * 1e18;
        IERC20 token = IERC20(address(hiro));
 
        vm.startPrank(notOwner);
        // Approve under notOwner
        token.approve(address(hiroWallet), depositAmount);
        vm.expectRevert("Not the owner");
        hiroWallet.deposit(address(hiro), depositAmount);
        vm.stopPrank();
    }
 
    // Test token withdrawal by owner.
    function testWithdrawTokens() public {
        uint256 depositAmount = 100 * 1e18;
        IERC20 token = IERC20(address(hiro));
 
        // Deposit tokens first.
        token.approve(address(hiroWallet), depositAmount);
        hiroWallet.deposit(address(hiro), depositAmount);
 
        // Owner withdraws tokens.
        uint256 ownerBalanceBefore = token.balanceOf(owner);
        hiroWallet.withdraw(address(hiro), depositAmount);
 
        uint256 ownerBalanceAfter = token.balanceOf(owner);
        assertEq(ownerBalanceAfter - ownerBalanceBefore, depositAmount);
    }
 
    // Test ETH deposit and withdrawal by owner.
    function testWithdrawETH() public {
        // Send ETH to the wallet using the receive function.
        uint256 depositEth = 1 ether;
        // As owner, send ETH.
        (bool sent, ) = address(hiroWallet).call{value: depositEth}("");
        require(sent, "ETH deposit failed");
 
        // Check contract balance.
        assertEq(address(hiroWallet).balance, depositEth);
 
        // Owner withdraws ETH.
        uint256 ownerEthBefore = owner.balance;
        // Call withdrawETH.
        hiroWallet.withdrawETH(depositEth);
 
        // After withdrawal, hirowallet balance should be zero.
        assertEq(address(hiroWallet).balance, 0);
 
        uint256 ownerEthAfter = owner.balance;
        // owner gains ETH (ignoring gas costs in test environment).
        assertEq(ownerEthAfter - ownerEthBefore, depositEth);
    }
 
    // Test execute() function success when called by an agent and target is whitelisted.
    function testExecuteSuccess() public {
        // Deploy dummy target.
        DummyTarget dummy = new DummyTarget();
 
        // For testing, override the whitelisted check via vm.mockCall.
        // When hirowallet calls isWhitelisted(dummy), return true.
        vm.mockCall(
            hiroWallet.factory(),
            abi.encodeWithSelector(IHiroFactory.isWhitelisted.selector, address(dummy)),
            abi.encode(true)
        );
 
        // Also ensure the caller is a valid agent.
        // Since the test agent is in agent variable, simulate agent call.
        bytes memory callData = abi.encodeWithSelector(dummy.doSomething.selector);
 
        vm.prank(agent);
        bytes memory result = hiroWallet.execute(address(dummy), callData);
 
        // Decode the result from dummy.doSomething() which should be 42.
        uint256 returnedVal = abi.decode(result, (uint256));
        assertEq(returnedVal, 42);
 
        // Check that dummy value is set.
        assertEq(dummy.value(), 42);
    }
 
    // Test execute() failure when caller is not an agent.
    function testExecuteFailNotAgent() public {
        DummyTarget dummy = new DummyTarget();
 
        // Ensure target is whitelisted.
        vm.mockCall(
            hiroWallet.factory(),
            abi.encodeWithSelector(IHiroFactory.isWhitelisted.selector, address(dummy)),
            abi.encode(true)
        );
 
        bytes memory callData = abi.encodeWithSelector(dummy.doSomething.selector);
 
        // As not an agent, call should revert.
        vm.prank(notOwner);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(address(dummy), callData);
    }
 
    // Test execute() failure when target is not whitelisted.
    function testExecuteFailTargetNotWhitelisted() public {
        DummyTarget dummy = new DummyTarget();
 
        // Mock isWhitelisted to return false.
        vm.mockCall(
            hiroWallet.factory(),
            abi.encodeWithSelector(IHiroFactory.isWhitelisted.selector, address(dummy)),
            abi.encode(false)
        );
 
        bytes memory callData = abi.encodeWithSelector(dummy.doSomething.selector);
 
        vm.prank(agent);
        vm.expectRevert("Address not whitelisted");
        hiroWallet.execute(address(dummy), callData);
    }
}