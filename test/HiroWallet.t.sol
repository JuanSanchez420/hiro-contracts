// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {IHiroFactory} from "../src/interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";

contract MockERC721 is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("MockNFT", "MNFT") {}

    function safeMint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://mock.uri/") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}

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
    address public nonOwner = address(0x9ABC);

    function setUp() public {
        vm.deal(user, 10 ether);

        address[] memory initialTargets = new address[](0);

        vm.prank(user);
        hiroFactory = new HiroFactory(initialTargets);
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

    function testOwnerCanExecuteSingleCall() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addTarget(address(mock));

        vm.deal(address(hiroWallet), 1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 42);
        uint256[] memory values = new uint256[](1);
        values[0] = 0.25 ether;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.value(), 42);
        assertEq(mock.lastReceivedValue(), 0.25 ether);
    }

    function testExecuteFailsForNonOwner() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addTarget(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 1);
        uint256[] memory values = new uint256[](1);

        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteFailsForUnwhitelistedTarget() public {
        MockContract mock = new MockContract();

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 1);
        uint256[] memory values = new uint256[](1);

        vm.prank(user);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteFailsWhenPaused() public {
        MockContract mock = new MockContract();
        vm.startPrank(user);
        hiroFactory.addTarget(address(mock));
        hiroFactory.pause();
        vm.stopPrank();

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 1);
        uint256[] memory values = new uint256[](1);

        vm.prank(user);
        vm.expectRevert(HiroFactory.Paused.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteBatchCalls() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addTarget(address(mock1));
        hiroFactory.addTarget(address(mock2));
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

        vm.prank(user);
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

        vm.prank(user);
        vm.expectRevert(HiroWallet.LengthMismatch.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteRevertsWhenNoCallsProvided() public {
        address[] memory targets = new address[](0);
        bytes[] memory dataArray = new bytes[](0);
        uint256[] memory values = new uint256[](0);

        vm.prank(user);
        vm.expectRevert(HiroWallet.EmptyCalls.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testExecuteRevertsWhenNotEnoughEth() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addTarget(address(mock));

        vm.deal(address(hiroWallet), 0.1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 5);
        uint256[] memory values = new uint256[](1);
        values[0] = 0.2 ether;

        vm.prank(user);
        vm.expectRevert(HiroWallet.InsufficientETH.selector);
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
        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.withdrawETH(0.1 ether);
    }

    function testWithdrawETHRevertsOnInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert(HiroWallet.InsufficientETH.selector);
        hiroWallet.withdrawETH(2 ether);
    }

    function testOwnerCanCallFactoryWithoutWhitelist() public {
        // Factory is implicitly trusted by the wallet (self-call carve-out in validateCall)
        assertFalse(hiroFactory.targetWhitelist(address(hiroFactory)));

        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(IHiroFactory.targetWhitelist.selector, address(0x1234));
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testOwnerCannotEscalateThroughFactoryCall() public {
        // The wallet's owner can call execute, and execute can call the factory (self-call carve-out),
        // but the factory's onlyOwner functions check msg.sender == factory.owner(), which is the
        // factory owner — NOT the wallet's owner. The wallet contract is not the factory owner.
        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        dataArray[0] = abi.encodeWithSelector(HiroFactory.addTarget.selector, address(0xBAD));
        vm.prank(user);
        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.execute(targets, dataArray, values);

        dataArray[0] = abi.encodeWithSelector(HiroFactory.removeTarget.selector, address(0x123));
        vm.prank(user);
        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.execute(targets, dataArray, values);

        dataArray[0] = abi.encodeWithSelector(HiroFactory.sweep.selector, address(mockToken), 1 ether);
        vm.prank(user);
        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.execute(targets, dataArray, values);

        dataArray[0] = abi.encodeWithSelector(HiroFactory.sweepETH.selector);
        vm.prank(user);
        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.execute(targets, dataArray, values);
    }

    function testFeeCollectionETHEndToEnd() public {
        // Simulate fee collection: wallet sends ETH to factory, owner sweeps it
        uint256 feeAmount = 0.1 ether;
        uint256 ownerBalanceBefore = user.balance;

        address[] memory targets = new address[](1);
        targets[0] = address(hiroFactory);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = "";
        uint256[] memory values = new uint256[](1);
        values[0] = feeAmount;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(address(hiroFactory).balance, feeAmount);

        vm.prank(user);
        hiroFactory.sweepETH();

        assertEq(address(hiroFactory).balance, 0);
        assertEq(user.balance, ownerBalanceBefore + feeAmount);
    }

    function testFeeCollectionTokenEndToEnd() public {
        uint256 feeAmount = 0.5 ether;
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(user);
        hiroFactory.addTarget(address(mockToken));

        address[] memory targets = new address[](1);
        targets[0] = address(mockToken);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(IERC20.transfer.selector, address(hiroFactory), feeAmount);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mockToken.balanceOf(address(hiroFactory)), feeAmount);

        vm.prank(user);
        hiroFactory.sweep(address(mockToken), feeAmount);

        assertEq(mockToken.balanceOf(address(hiroFactory)), 0);
        assertEq(mockToken.balanceOf(user), feeAmount);
    }

    function testNonOwnerCannotSweepFactory() public {
        vm.deal(address(hiroFactory), 1 ether);
        mockToken.mint(address(hiroFactory), 1 ether);

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweep(address(mockToken), 1 ether);
    }

    function testFactoryReceiveDoesNotCreateVulnerability() public {
        address randomSender = address(0xDEAD);
        vm.deal(randomSender, 1 ether);

        vm.prank(randomSender);
        (bool success,) = address(hiroFactory).call{value: 0.5 ether}("");
        assertTrue(success);

        assertEq(address(hiroFactory).balance, 0.5 ether);

        vm.prank(randomSender);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();

        uint256 ownerBalanceBefore = user.balance;
        vm.prank(user);
        hiroFactory.sweepETH();
        assertEq(user.balance, ownerBalanceBefore + 0.5 ether);
    }

    // ==================== ADDITIONAL COVERAGE TESTS ====================

    function testOwnerCanWithdrawNonWhitelistedToken() public {
        // Owners can withdraw any token regardless of factory whitelist
        MockERC20 randomToken = new MockERC20();
        randomToken.mint(address(hiroWallet), 1 ether);

        assertFalse(hiroFactory.targetWhitelist(address(randomToken)));

        vm.prank(user);
        hiroWallet.withdraw(address(randomToken), 1 ether);

        assertEq(randomToken.balanceOf(user), 1 ether);
    }

    function testNonOwnerCannotWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.withdraw(address(mockToken), 0.5 ether);
    }

    function testBatchPartialFailureRevertsAll() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addTarget(address(mock1));
        // mock2 NOT whitelisted
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(mock1);
        targets[1] = address(mock2);
        bytes[] memory dataArray = new bytes[](2);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 10);
        dataArray[1] = abi.encodeWithSelector(MockContract.setValue.selector, 20);
        uint256[] memory values = new uint256[](2);

        vm.prank(user);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.execute(targets, dataArray, values);

        // First call should NOT have persisted (atomic revert)
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

    function testFactorySweepTokens() public {
        mockToken.mint(address(hiroFactory), 1 ether);

        uint256 balanceBefore = mockToken.balanceOf(user);

        vm.prank(user);
        hiroFactory.sweep(address(mockToken), 0.5 ether);

        assertEq(mockToken.balanceOf(user), balanceBefore + 0.5 ether);
        assertEq(mockToken.balanceOf(address(hiroFactory)), 0.5 ether);
    }

    function testWalletImmutables() public view {
        assertEq(hiroWallet.owner(), user);
        assertEq(hiroWallet.factory(), address(hiroFactory));
    }

    // ==================== EDGE CASE TESTS ====================

    function testWithdrawZeroTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        uint256 balanceBefore = mockToken.balanceOf(user);
        vm.prank(user);
        hiroWallet.withdraw(address(mockToken), 0);

        assertEq(mockToken.balanceOf(user), balanceBefore);
        assertEq(mockToken.balanceOf(address(hiroWallet)), 1 ether);
    }

    function testWithdrawZeroETH() public {
        uint256 initialWalletBalance = address(hiroWallet).balance;
        uint256 initialUserBalance = user.balance;

        vm.prank(user);
        hiroWallet.withdrawETH(0);

        assertEq(address(hiroWallet).balance, initialWalletBalance);
        assertEq(user.balance, initialUserBalance);
    }

    function testExecuteWithZeroValueTransfer() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addTarget(address(mock));

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 100);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.value(), 100);
        assertEq(mock.lastReceivedValue(), 0);
    }

    function testBatchExecutionFirstCallSucceedsSecondFails() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();

        vm.startPrank(user);
        hiroFactory.addTarget(address(mock1));
        hiroFactory.addTarget(address(mock2));
        vm.stopPrank();

        vm.deal(address(hiroWallet), 0.5 ether);

        address[] memory targets = new address[](2);
        targets[0] = address(mock1);
        targets[1] = address(mock2);
        bytes[] memory dataArray = new bytes[](2);
        dataArray[0] = abi.encodeWithSelector(MockContract.setValue.selector, 10);
        dataArray[1] = abi.encodeWithSelector(MockContract.setValue.selector, 20);
        uint256[] memory values = new uint256[](2);
        values[0] = 0.3 ether;
        values[1] = 0.3 ether;

        vm.prank(user);
        vm.expectRevert(HiroWallet.InsufficientETH.selector);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock1.value(), 0);
    }

    function testExecuteEmptyCalldata() public {
        MockContract mock = new MockContract();
        vm.prank(user);
        hiroFactory.addTarget(address(mock));

        vm.deal(address(hiroWallet), 1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(mock);
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = "";
        uint256[] memory values = new uint256[](1);
        values[0] = 0.25 ether;

        vm.prank(user);
        hiroWallet.execute(targets, dataArray, values);

        assertEq(mock.lastReceivedValue(), 0.25 ether);
    }

    // ==================== ERC721/ERC1155 RECEIVER TESTS ====================

    function testCanReceiveERC721() public {
        MockERC721 nft = new MockERC721();
        uint256 tokenId = nft.safeMint(address(hiroWallet));
        assertEq(nft.ownerOf(tokenId), address(hiroWallet));
    }

    function testCanReceiveERC1155() public {
        MockERC1155 token = new MockERC1155();
        token.mint(address(hiroWallet), 1, 100);
        assertEq(token.balanceOf(address(hiroWallet), 1), 100);
    }

    function testCanReceiveERC1155Batch() public {
        MockERC1155 token = new MockERC1155();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10;
        amounts[1] = 20;
        amounts[2] = 30;

        token.mintBatch(address(hiroWallet), ids, amounts);

        assertEq(token.balanceOf(address(hiroWallet), 1), 10);
        assertEq(token.balanceOf(address(hiroWallet), 2), 20);
        assertEq(token.balanceOf(address(hiroWallet), 3), 30);
    }

    function testMultipleWithdrawals() public {
        mockToken.mint(address(hiroWallet), 1 ether);
        vm.deal(address(hiroWallet), 1 ether);

        vm.startPrank(user);

        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.4 ether);

        assertEq(mockToken.balanceOf(user), 1 ether);
        assertEq(mockToken.balanceOf(address(hiroWallet)), 0);

        uint256 initialBalance = user.balance;
        hiroWallet.withdrawETH(0.5 ether);
        hiroWallet.withdrawETH(0.5 ether);

        assertEq(user.balance, initialBalance + 1 ether);
        assertEq(address(hiroWallet).balance, 0);

        vm.stopPrank();
    }
}
