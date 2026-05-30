// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {IHiroWallet} from "../src/interfaces/IHiroWallet.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {NoopStrategy} from "./mocks/NoopStrategy.sol";
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
    bool public shouldRevert;

    function setValue(uint256 newValue) external payable {
        if (shouldRevert) revert("mock-revert");
        value = newValue;
        lastReceivedValue = msg.value;
    }

    function setRevert(bool b) external {
        shouldRevert = b;
    }

    receive() external payable {
        if (shouldRevert) revert("mock-revert");
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

    uint256 internal ownerPk = 0xA11CE;
    address internal user;
    address internal nonOwner = address(0x9ABC);
    address internal relayer = address(0xBEEF);

    function setUp() public {
        user = vm.addr(ownerPk);
        vm.deal(user, 10 ether);

        address[] memory initialTargets = new address[](0);

        vm.prank(user);
        hiroFactory = new HiroFactory(initialTargets);
        mockToken = new MockERC20();

        vm.startPrank(user);
        hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet{value: 1 ether}()));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    function _hashCalls(IHiroWallet.Call[] memory calls) internal view returns (bytes32) {
        bytes32 callTypehash = hiroWallet.CALL_TYPEHASH();
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashes[i] = keccak256(abi.encode(callTypehash, calls[i].target, keccak256(calls[i].data), calls[i].value));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _digest(IHiroWallet.Call[] memory calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(hiroWallet.EXECUTE_TYPEHASH(), address(hiroWallet), user, _hashCalls(calls), nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", hiroWallet.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _singleCall(address target, bytes memory data, uint256 value)
        internal
        pure
        returns (IHiroWallet.Call[] memory calls)
    {
        calls = new IHiroWallet.Call[](1);
        calls[0] = IHiroWallet.Call({target: target, data: data, value: value});
    }

    function _addTarget(address target) internal {
        vm.prank(user);
        hiroFactory.addTarget(target);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeWithOwnerSig — happy path & state
    // ═══════════════════════════════════════════════════════════════════════════

    function testExecuteWithOwnerSig_happyPath_anyRelayer() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls =
            _singleCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 42), 0.25 ether);

        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, nonce, deadline));

        assertFalse(hiroWallet.isNonceUsed(nonce));

        vm.prank(relayer);
        hiroWallet.executeWithOwnerSig(calls, nonce, deadline, sig);

        assertEq(mock.value(), 42);
        assertEq(mock.lastReceivedValue(), 0.25 ether);
        assertTrue(hiroWallet.isNonceUsed(nonce));
    }

    function testExecuteWithOwnerSig_batch() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();
        _addTarget(address(mock1));
        _addTarget(address(mock2));

        IHiroWallet.Call[] memory calls = new IHiroWallet.Call[](2);
        calls[0] = IHiroWallet.Call({
            target: address(mock1),
            data: abi.encodeWithSelector(MockContract.setValue.selector, 10),
            value: 0.1 ether
        });
        calls[1] = IHiroWallet.Call({
            target: address(mock2),
            data: abi.encodeWithSelector(MockContract.setValue.selector, 20),
            value: 0.2 ether
        });

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 7, deadline));

        vm.prank(relayer);
        hiroWallet.executeWithOwnerSig(calls, 7, deadline, sig);

        assertEq(mock1.value(), 10);
        assertEq(mock2.value(), 20);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeWithOwnerSig — signature failure modes
    // ═══════════════════════════════════════════════════════════════════════════

    function testExecuteWithOwnerSig_wrongSigner_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(uint256(0xBADBADBAD), _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_modifiedTarget_reverts() public {
        MockContract mock = new MockContract();
        MockContract other = new MockContract();
        _addTarget(address(mock));
        _addTarget(address(other));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        calls[0].target = address(other);
        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_modifiedData_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls =
            _singleCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 1), 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        calls[0].data = abi.encodeWithSelector(MockContract.setValue.selector, 999);
        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_modifiedValue_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0.1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        calls[0].value = 0.2 ether;
        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_modifiedNonce_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 2, deadline, sig);
    }

    function testExecuteWithOwnerSig_modifiedDeadline_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 originalDeadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, originalDeadline));

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, originalDeadline + 1, sig);
    }

    function testExecuteWithOwnerSig_wrongWallet_reverts() public {
        // Signature carries this wallet's address in the digest. A second wallet
        // for the same owner should not accept the same signature.
        address user2 = address(0xCAFE);
        vm.prank(user2);
        HiroWallet other = HiroWallet(payable(hiroFactory.createHiroWallet()));

        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        // Sign a digest bound to `hiroWallet` then try to redeem at `other`.
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        other.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_wrongChainId_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.chainId(999);
        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_replay_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);

        vm.expectRevert(HiroWallet.NonceAlreadyUsed.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_expired_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.ExpiredDeadline.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_highSMalleability_reverts() public {
        // Force a high-s signature. vm.sign returns canonical low-s; flip via secp256k1.n - s
        // and bump v from 27<->28 to remain a valid signature for the inverted point.
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(calls, 1, deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory sig = abi.encodePacked(r, highS, flippedV);

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeAsOwner
    // ═══════════════════════════════════════════════════════════════════════════

    function testExecuteAsOwner_happyPath() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls =
            _singleCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 42), 0.25 ether);

        vm.prank(user);
        hiroWallet.executeAsOwner(calls);

        assertEq(mock.value(), 42);
        assertEq(mock.lastReceivedValue(), 0.25 ether);
    }

    function testExecuteAsOwner_nonOwner_reverts() public {
        IHiroWallet.Call[] memory calls = _singleCall(address(0xDEAD), "", 0);

        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.executeAsOwner(calls);
    }

    function testExecuteAsOwner_doesNotConsumeNonce() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);

        // executeAsOwner uses no nonce; the bitmap remains empty.
        vm.prank(user);
        hiroWallet.executeAsOwner(calls);

        assertFalse(hiroWallet.isNonceUsed(0));
        assertFalse(hiroWallet.isNonceUsed(1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // invalidateNonce
    // ═══════════════════════════════════════════════════════════════════════════

    function testInvalidateNonce_consumes() public {
        vm.prank(user);
        hiroWallet.invalidateNonce(42);

        assertTrue(hiroWallet.isNonceUsed(42));

        // A subsequent signature bound to nonce 42 must now be unredeemable.
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 42, deadline));

        vm.expectRevert(HiroWallet.NonceAlreadyUsed.selector);
        hiroWallet.executeWithOwnerSig(calls, 42, deadline, sig);
    }

    function testInvalidateNonce_nonOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.invalidateNonce(42);
    }

    function testInvalidateNonce_twice_reverts() public {
        vm.startPrank(user);
        hiroWallet.invalidateNonce(7);
        vm.expectRevert(HiroWallet.NonceAlreadyUsed.selector);
        hiroWallet.invalidateNonce(7);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Factory pause / target whitelist integration
    // ═══════════════════════════════════════════════════════════════════════════

    function testExecuteWithOwnerSig_pauseHaltsRelay() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        vm.prank(user);
        hiroFactory.pause();

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroFactory.Paused.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);

        // Whole transaction reverted, so the nonce-bitmap write rolled back too.
        assertFalse(hiroWallet.isNonceUsed(1));
    }

    function testExecuteWithOwnerSig_unpauseThenReplaySameNonceSucceeds() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        vm.prank(user);
        hiroFactory.pause();

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroFactory.Paused.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);

        vm.prank(user);
        hiroFactory.unpause();

        // Same signature, same nonce — the previous attempt's nonce write rolled back atomically.
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
        assertTrue(hiroWallet.isNonceUsed(1));
    }

    function testExecuteWithOwnerSig_nonWhitelistedTarget_reverts() public {
        MockContract mock = new MockContract(); // not added to whitelist

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_selfCallToFactoryAllowed() public {
        // Factory is not in the whitelist; self-call carve-out lets a real factory function
        // dispatch through. Use a non-empty calldata so this actually exercises the dispatcher,
        // not just the factory's receive().
        assertFalse(hiroFactory.targetWhitelist(address(hiroFactory)));
        IHiroWallet.Call[] memory calls = _singleCall(
            address(hiroFactory), abi.encodeWithSelector(hiroFactory.targetWhitelist.selector, address(0x1234)), 0
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.prank(relayer);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_insufficientEth_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 100 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.InsufficientETH.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    function testExecuteWithOwnerSig_innerCallReverts_rollsBackBundle() public {
        MockContract mock1 = new MockContract();
        MockContract mock2 = new MockContract();
        _addTarget(address(mock1));
        _addTarget(address(mock2));
        mock2.setRevert(true);

        IHiroWallet.Call[] memory calls = new IHiroWallet.Call[](2);
        calls[0] = IHiroWallet.Call({
            target: address(mock1),
            data: abi.encodeWithSelector(MockContract.setValue.selector, 10),
            value: 0
        });
        calls[1] = IHiroWallet.Call({
            target: address(mock2),
            data: abi.encodeWithSelector(MockContract.setValue.selector, 20),
            value: 0
        });

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);

        // Atomic rollback: the first call's state change is undone.
        assertEq(mock1.value(), 0);
        // Nonce burn rolls back too because the entire tx reverted.
        assertFalse(hiroWallet.isNonceUsed(1));
    }

    function testExecuteWithOwnerSig_emptyCalls_reverts() public {
        IHiroWallet.Call[] memory calls = new IHiroWallet.Call[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.expectRevert(HiroWallet.EmptyCalls.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-1271 path
    // ═══════════════════════════════════════════════════════════════════════════

    function _deployWalletWithOwner(address newOwner) internal returns (HiroWallet) {
        vm.prank(newOwner);
        return HiroWallet(payable(hiroFactory.createHiroWallet()));
    }

    function testErc1271_validSignatureExecutes() public {
        MockERC1271Wallet contractOwner = new MockERC1271Wallet();
        HiroWallet wallet = _deployWalletWithOwner(address(contractOwner));

        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls =
            _singleCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                wallet.EXECUTE_TYPEHASH(), address(wallet), address(contractOwner), _hashCalls(calls), 1, deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", wallet.DOMAIN_SEPARATOR(), structHash));
        bytes memory sig = hex"deadbeef";

        contractOwner.setValid(digest, sig);

        wallet.executeWithOwnerSig(calls, 1, deadline, sig);
        assertEq(mock.value(), 7);
    }

    function testErc1271_invalidSignature_reverts() public {
        MockERC1271Wallet contractOwner = new MockERC1271Wallet();
        HiroWallet wallet = _deployWalletWithOwner(address(contractOwner));

        MockContract mock = new MockContract();
        _addTarget(address(mock));

        IHiroWallet.Call[] memory calls = _singleCall(address(mock), "", 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"deadbeef"; // never registered as valid

        vm.expectRevert(HiroWallet.InvalidSignature.selector);
        wallet.executeWithOwnerSig(calls, 1, deadline, sig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // withdraw / withdrawETH (unchanged from Stage 2 behavior)
    // ═══════════════════════════════════════════════════════════════════════════

    function testOwnerCanWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(user);
        hiroWallet.withdraw(address(mockToken), 0.4 ether);

        assertEq(mockToken.balanceOf(user), 0.4 ether);
    }

    function testOwnerCanWithdrawETH() public {
        uint256 initialUserBalance = user.balance;
        vm.prank(user);
        hiroWallet.withdrawETH(0.5 ether);

        assertEq(user.balance, initialUserBalance + 0.5 ether);
    }

    function testNonOwnerCannotWithdrawETH() public {
        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.withdrawETH(0.1 ether);
    }

    function testNonOwnerCannotWithdrawTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwner.selector);
        hiroWallet.withdraw(address(mockToken), 0.5 ether);
    }

    function testWithdrawETHRevertsOnInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert(HiroWallet.InsufficientETH.selector);
        hiroWallet.withdrawETH(2 ether);
    }

    function testWithdrawZeroTokens() public {
        mockToken.mint(address(hiroWallet), 1 ether);
        vm.prank(user);
        hiroWallet.withdraw(address(mockToken), 0);
    }

    function testWithdrawZeroETH() public {
        vm.prank(user);
        hiroWallet.withdrawETH(0);
    }

    function testMultipleWithdrawals() public {
        mockToken.mint(address(hiroWallet), 1 ether);

        vm.startPrank(user);
        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.3 ether);
        hiroWallet.withdraw(address(mockToken), 0.4 ether);
        assertEq(mockToken.balanceOf(user), 1 ether);

        uint256 initialBalance = user.balance;
        hiroWallet.withdrawETH(0.5 ether);
        hiroWallet.withdrawETH(0.5 ether);
        assertEq(user.balance, initialBalance + 1 ether);
        vm.stopPrank();
    }

    function testWalletImmutables() public view {
        assertEq(hiroWallet.owner(), user);
        assertEq(hiroWallet.factory(), address(hiroFactory));
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

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC721 / ERC1155 receivers
    // ═══════════════════════════════════════════════════════════════════════════

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
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;
        token.mintBatch(address(hiroWallet), ids, amounts);

        assertEq(token.balanceOf(address(hiroWallet), 1), 10);
        assertEq(token.balanceOf(address(hiroWallet), 2), 20);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Factory-side integration (kept from Stage 2)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFactoryReceiveDoesNotCreateVulnerability() public {
        address randomSender = address(0xDEAD);
        vm.deal(randomSender, 1 ether);

        vm.prank(randomSender);
        (bool success,) = address(hiroFactory).call{value: 0.5 ether}("");
        assertTrue(success);

        vm.prank(randomSender);
        vm.expectRevert("Ownable: caller is not the owner");
        hiroFactory.sweepETH();

        uint256 ownerBalanceBefore = user.balance;
        vm.prank(user);
        hiroFactory.sweepETH();
        assertEq(user.balance, ownerBalanceBefore + 0.5 ether);
    }

    function testFactorySweepTokens() public {
        mockToken.mint(address(hiroFactory), 1 ether);
        uint256 balanceBefore = mockToken.balanceOf(user);

        vm.prank(user);
        hiroFactory.sweep(address(mockToken), 0.5 ether);

        assertEq(mockToken.balanceOf(user), balanceBefore + 0.5 ether);
    }

    function testFeeCollectionETHEndToEnd_viaExecuteAsOwner() public {
        uint256 feeAmount = 0.1 ether;
        uint256 ownerBalanceBefore = user.balance;

        IHiroWallet.Call[] memory calls = _singleCall(address(hiroFactory), "", feeAmount);
        vm.prank(user);
        hiroWallet.executeAsOwner(calls);

        assertEq(address(hiroFactory).balance, feeAmount);

        vm.prank(user);
        hiroFactory.sweepETH();

        assertEq(user.balance, ownerBalanceBefore + feeAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeStrategy
    // ═══════════════════════════════════════════════════════════════════════════

    event StrategyExecuted(address indexed strategy, address indexed agent);

    function _addAgent(address a) internal {
        vm.prank(user);
        hiroFactory.addAgent(a);
    }

    function _addStrategy(address s) internal {
        vm.prank(user);
        hiroFactory.addStrategy(s);
    }

    function _enableStrategy(address s) internal {
        vm.prank(user);
        hiroWallet.setStrategy(s, true);
    }

    function _encodeNoopCall(address target, bytes memory data, uint256 value) internal pure returns (bytes memory) {
        return abi.encode(target, data, value);
    }

    function testExecuteStrategy_happyPath_singleCall() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.expectEmit(true, true, false, false, address(hiroWallet));
        emit StrategyExecuted(address(strat), relayer);

        vm.prank(relayer);
        hiroWallet.executeStrategy(strat, params);

        assertEq(mock.value(), 7);
    }

    function testExecuteStrategy_happyPath_withValue() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params = _encodeNoopCall(address(mock), "", 0.1 ether);

        vm.prank(relayer);
        hiroWallet.executeStrategy(strat, params);

        assertEq(mock.lastReceivedValue(), 0.1 ether);
    }

    function testExecuteStrategy_nonAgentCaller_reverts() public {
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.NotAgent.selector);
        hiroWallet.executeStrategy(strat, "");
    }

    function testExecuteStrategy_nonWhitelistedStrategy_reverts() public {
        NoopStrategy strat = new NoopStrategy();
        _addAgent(relayer);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.StrategyNotWhitelisted.selector);
        hiroWallet.executeStrategy(strat, "");
    }

    function testExecuteStrategy_pausedFactory_reverts() public {
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _addAgent(relayer);
        vm.prank(user);
        hiroFactory.pause();

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.FactoryPaused.selector);
        hiroWallet.executeStrategy(strat, "");
    }

    function testExecuteStrategy_strategyReturnsNonWhitelistedTarget_reverts() public {
        MockContract mock = new MockContract();
        // mock NOT whitelisted
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.prank(relayer);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.executeStrategy(strat, params);
    }

    function testExecuteStrategy_emptyCallsFromPlan_reverts() public {
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.EmptyCalls.selector);
        hiroWallet.executeStrategy(strat, "");
    }

    function testExecuteStrategy_insufficientETH_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params = _encodeNoopCall(address(mock), "", 100 ether);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.InsufficientETH.selector);
        hiroWallet.executeStrategy(strat, params);
    }

    function testExecuteStrategy_calleeReverts_propagates() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        mock.setRevert(true);
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.CallFailed.selector);
        hiroWallet.executeStrategy(strat, params);
    }

    function testExecuteStrategy_doesNotConsumeNonce() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.prank(relayer);
        hiroWallet.executeStrategy(strat, params);

        assertFalse(hiroWallet.isNonceUsed(1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // setStrategy — per-wallet opt-in (mass-drain firewall)
    // ═══════════════════════════════════════════════════════════════════════════

    event StrategyEnabled(address indexed strategy, bool enabled);

    /// @dev Core property: a strategy that is on the factory's global whitelist AND invoked by a
    /// whitelisted agent still cannot run unless this wallet's owner opted in. This is exactly the
    /// scenario of a compromised factory key (it controls both whitelists) — it cannot drain.
    function testExecuteStrategy_whitelistedButNotEnabled_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat)); // global strategy whitelist (factory owner)
        _addAgent(relayer); // global agent whitelist (factory owner)
        // NOTE: wallet owner never called setStrategy.

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.StrategyNotEnabled.selector);
        hiroWallet.executeStrategy(strat, params);

        assertEq(mock.value(), 0);
    }

    /// @dev A compromised factory key registers a malicious strategy + agent and tries to sweep a
    /// token out of a wallet that never opted in. The opt-in firewall stops it; funds are intact.
    function testExecuteStrategy_compromisedFactoryCannotDrain() public {
        address attacker = address(0xDEAD);
        mockToken.mint(address(hiroWallet), 1_000 ether);
        _addTarget(address(mockToken)); // token is a normal whitelisted target

        NoopStrategy evil = new NoopStrategy();
        _addStrategy(address(evil)); // attacker (factory owner) whitelists malicious strategy
        _addAgent(attacker); // ...and a malicious agent

        // Strategy plan = transfer the wallet's entire token balance to the attacker.
        bytes memory drainCall = _encodeNoopCall(
            address(mockToken), abi.encodeWithSelector(IERC20.transfer.selector, attacker, 1_000 ether), 0
        );

        vm.prank(attacker);
        vm.expectRevert(HiroWallet.StrategyNotEnabled.selector);
        hiroWallet.executeStrategy(evil, drainCall);

        assertEq(mockToken.balanceOf(address(hiroWallet)), 1_000 ether);
        assertEq(mockToken.balanceOf(attacker), 0);
    }

    function testSetStrategy_ownerEnablesAndDisables() public {
        address strat = address(0x57A7);

        vm.expectEmit(true, false, false, true, address(hiroWallet));
        emit StrategyEnabled(strat, true);
        vm.prank(user);
        hiroWallet.setStrategy(strat, true);
        assertTrue(hiroWallet.enabledStrategies(strat));

        vm.expectEmit(true, false, false, true, address(hiroWallet));
        emit StrategyEnabled(strat, false);
        vm.prank(user);
        hiroWallet.setStrategy(strat, false);
        assertFalse(hiroWallet.enabledStrategies(strat));
    }

    function testSetStrategy_nonOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(HiroWallet.NotOwnerOrSelf.selector);
        hiroWallet.setStrategy(address(0x57A7), true);
    }

    function testSetStrategy_agentCannotEnable_reverts() public {
        _addAgent(relayer);
        vm.prank(relayer);
        vm.expectRevert(HiroWallet.NotOwnerOrSelf.selector);
        hiroWallet.setStrategy(address(0x57A7), true);
    }

    /// @dev Gasless opt-in: the owner signs a bundle that calls the wallet's own setStrategy, and
    /// any relayer submits it via executeWithOwnerSig (an owner-authorized path, so _execute runs
    /// with allowSelf=true). The strategy then runs. No new EIP-712 machinery — reuses the existing
    /// signed-bundle path.
    function testSetStrategy_gaslessViaOwnerSig() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _addAgent(relayer);

        // Owner signs: [ wallet.setStrategy(strat, true) ]
        IHiroWallet.Call[] memory calls = _singleCall(
            address(hiroWallet), abi.encodeWithSelector(hiroWallet.setStrategy.selector, address(strat), true), 0
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        assertFalse(hiroWallet.enabledStrategies(address(strat)));
        vm.prank(relayer); // relayer pays gas, not the owner
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);
        assertTrue(hiroWallet.enabledStrategies(address(strat)));

        // Now the agent can execute the opted-in strategy.
        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 42), 0);
        vm.prank(relayer);
        hiroWallet.executeStrategy(strat, params);
        assertEq(mock.value(), 42);
    }

    /// @dev Opt-in is revocable: once disabled, the agent can no longer run the strategy.
    function testExecuteStrategy_disabledAfterEnable_reverts() public {
        MockContract mock = new MockContract();
        _addTarget(address(mock));
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        bytes memory params =
            _encodeNoopCall(address(mock), abi.encodeWithSelector(MockContract.setValue.selector, 7), 0);

        vm.prank(relayer);
        hiroWallet.executeStrategy(strat, params);
        assertEq(mock.value(), 7);

        // Owner revokes.
        vm.prank(user);
        hiroWallet.setStrategy(address(strat), false);

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.StrategyNotEnabled.selector);
        hiroWallet.executeStrategy(strat, params);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Self-call scoping: strategy output may never target the wallet itself
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Core regression test. The wallet self-call carve-out is owner-authorized only. An
    /// enabled strategy whose plan() returns a self-call to setStrategy must NOT be able to
    /// escalate by enabling other strategies — executeStrategy runs _execute(allowSelf=false).
    function testExecuteStrategy_selfCall_reverts() public {
        address otherStrat = address(0x07E2);
        NoopStrategy strat = new NoopStrategy();
        _addStrategy(address(strat));
        _enableStrategy(address(strat));
        _addAgent(relayer);

        // plan() = [ wallet.setStrategy(otherStrat, true) ] — a self-call.
        bytes memory params = _encodeNoopCall(
            address(hiroWallet), abi.encodeWithSelector(hiroWallet.setStrategy.selector, otherStrat, true), 0
        );

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.SelfCallNotAllowed.selector);
        hiroWallet.executeStrategy(strat, params);

        // No privilege escalation: the self-targeted setStrategy never ran.
        assertFalse(hiroWallet.enabledStrategies(otherStrat));
    }

    /// @dev Positive control for the owner-authorized self-call path via executeAsOwner
    /// (allowSelf=true). The gasless test covers executeWithOwnerSig; this covers the direct path.
    function testExecuteAsOwner_selfCall_setStrategy() public {
        address strat = address(0x57A7);

        IHiroWallet.Call[] memory calls =
            _singleCall(address(hiroWallet), abi.encodeWithSelector(hiroWallet.setStrategy.selector, strat, true), 0);

        assertFalse(hiroWallet.enabledStrategies(strat));
        vm.prank(user);
        hiroWallet.executeAsOwner(calls);
        assertTrue(hiroWallet.enabledStrategies(strat));
    }

    /// @dev Pause parity: a paused factory still blocks an owner-signed self-call bundle. The
    /// self-call branch checks pause directly, so the revert is the wallet's FactoryPaused
    /// (vs HiroFactory.Paused for non-self targets, see testExecuteWithOwnerSig_pauseHaltsRelay).
    function testExecuteWithOwnerSig_selfCall_pausedReverts() public {
        address strat = address(0x57A7);

        IHiroWallet.Call[] memory calls =
            _singleCall(address(hiroWallet), abi.encodeWithSelector(hiroWallet.setStrategy.selector, strat, true), 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerPk, _digest(calls, 1, deadline));

        vm.prank(user);
        hiroFactory.pause();

        vm.prank(relayer);
        vm.expectRevert(HiroWallet.FactoryPaused.selector);
        hiroWallet.executeWithOwnerSig(calls, 1, deadline, sig);

        assertFalse(hiroWallet.enabledStrategies(strat));
    }
}
