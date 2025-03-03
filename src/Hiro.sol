// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract Hiro is ERC20 {
    string public logoURI;

    constructor() ERC20("Hiro Token", "HIRO") {
        logoURI = "https://onchainhiro.ai/logo.png";
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}
