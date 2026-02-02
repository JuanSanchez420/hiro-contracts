// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20Burnable.sol";

/// @title HiroToken
/// @notice Fixed-supply ERC20 token with burn capability for the Hiro seasonal token system
/// @dev All tokens are minted to the HiroSeason contract at deployment. No mint function exposed.
contract HiroToken is ERC20Burnable {
    constructor(address hiroSeason, uint256 totalSupply) ERC20("Hiro Token", "HIRO") {
        _mint(hiroSeason, totalSupply);
    }
}
