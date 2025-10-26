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

        hiroFactory = new HiroFactory(user, whitelist, agents);
        mockToken = new MockERC20();

        vm.startPrank(user);
        hiroWallet = HiroWallet(
            payable(
                hiroFactory.createHiroWallet{
                    value: hiroFactory.purchasePrice() + 1 ether
                }()
            )
        );
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
}
