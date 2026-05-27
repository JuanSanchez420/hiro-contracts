// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockERC1271Wallet
/// @notice Minimal ERC-1271 implementation that returns the magic value only when the caller
/// presents a (digest, signature) pair that was pre-registered with `setValid`. Anything else
/// returns the invalid sentinel so SignatureChecker rejects it.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    mapping(bytes32 => mapping(bytes32 => bool)) internal valid;

    function setValid(bytes32 digest, bytes calldata signature) external {
        valid[digest][keccak256(signature)] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (valid[hash][keccak256(signature)]) return MAGIC_VALUE;
        return 0xffffffff;
    }
}
