// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IHiroFactory.sol";
import "./interfaces/IHiroWallet.sol";
import "./interfaces/IStrategy.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import "lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

contract HiroWallet is IHiroWallet, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ExpiredDeadline();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error CallFailed();
    error InsufficientETH();
    error EthTransferFailed();
    error EmptyCalls();
    error NotAgent();
    error StrategyNotWhitelisted();
    error FactoryPaused();

    /// @dev EIP-712 struct hash for a single Call.
    bytes32 public constant CALL_TYPEHASH = keccak256("Call(address target,bytes data,uint256 value)");

    /// @dev EIP-712 struct hash for an Execute message. Referenced Call struct is appended per spec.
    bytes32 public constant EXECUTE_TYPEHASH = keccak256(
        "Execute(address wallet,address owner,Call[] calls,uint256 nonce,uint256 deadline)Call(address target,bytes data,uint256 value)"
    );

    address public immutable owner;
    address public immutable factory;

    /// @dev Permit2-style bitmap: `nonce >> 8` selects the slot, low 8 bits select the bit.
    mapping(uint256 => uint256) public nonceBitmap;

    event Executed(address indexed target, uint256 value);
    event NonceInvalidated(uint256 indexed nonce);
    event StrategyExecuted(address indexed strategy, address indexed agent);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) payable EIP712("HiroWallet", "1") {
        owner = _owner;
        factory = msg.sender;
    }

    receive() external payable {}

    /// @notice Domain separator for the wallet's EIP-712 messages.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner nonReentrant {
        if (amount > address(this).balance) revert InsufficientETH();
        (bool success,) = payable(owner).call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    /// @notice Execute a bundle signed by the owner. Anyone may relay.
    function executeWithOwnerSig(Call[] calldata calls, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (calls.length == 0) revert EmptyCalls();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(EXECUTE_TYPEHASH, address(this), owner, _hashCalls(calls), nonce, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) revert InvalidSignature();

        _consumeNonce(nonce);
        _execute(calls);
    }

    /// @notice Execute a bundle directly as owner. No nonce, no signature.
    function executeAsOwner(Call[] calldata calls) external onlyOwner nonReentrant {
        _execute(calls);
    }

    /// @notice Execute a whitelisted strategy. Caller must be a whitelisted agent.
    function executeStrategy(IStrategy strategy, bytes calldata params) external nonReentrant {
        IHiroFactory f = IHiroFactory(factory);
        if (f.paused()) revert FactoryPaused();
        if (!f.agentWhitelist(msg.sender)) revert NotAgent();
        if (!f.strategyWhitelist(address(strategy))) revert StrategyNotWhitelisted();

        Call[] memory calls = strategy.plan(address(this), params);
        _execute(calls);
        emit StrategyExecuted(address(strategy), msg.sender);
    }

    /// @notice Mark a nonce as used so any signature bound to it can no longer be submitted.
    function invalidateNonce(uint256 nonce) external onlyOwner {
        _consumeNonce(nonce);
        emit NonceInvalidated(nonce);
    }

    /// @notice True if the bit for `nonce` has been consumed.
    function isNonceUsed(uint256 nonce) external view returns (bool) {
        uint256 wordPos = nonce >> 8;
        uint256 bit = 1 << uint8(nonce);
        return (nonceBitmap[wordPos] & bit) != 0;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    function _consumeNonce(uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bit = 1 << uint8(nonce);
        uint256 word = nonceBitmap[wordPos];
        if (word & bit != 0) revert NonceAlreadyUsed();
        nonceBitmap[wordPos] = word | bit;
    }

    function _hashCalls(Call[] calldata calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashes[i] = keccak256(abi.encode(CALL_TYPEHASH, calls[i].target, keccak256(calls[i].data), calls[i].value));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _execute(Call[] memory calls) internal {
        uint256 length = calls.length;
        if (length == 0) revert EmptyCalls();

        uint256 totalEth;
        for (uint256 i = 0; i < length; i++) {
            totalEth += calls[i].value;
        }
        if (totalEth > address(this).balance) revert InsufficientETH();

        for (uint256 i = 0; i < length; i++) {
            IHiroFactory(factory).validateCall(calls[i].target);

            (bool success,) = payable(calls[i].target).call{value: calls[i].value}(calls[i].data);
            if (!success) revert CallFailed();

            emit Executed(calls[i].target, calls[i].value);
        }
    }
}
