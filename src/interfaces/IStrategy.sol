// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHiroWallet} from "./IHiroWallet.sol";

interface IStrategy {
    function plan(address wallet, bytes calldata params) external view returns (IHiroWallet.Call[] memory);
}
