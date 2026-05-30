// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHiroWallet {
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }
}
