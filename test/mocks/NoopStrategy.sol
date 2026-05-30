// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IHiroWallet} from "../../src/interfaces/IHiroWallet.sol";

contract NoopStrategy is IStrategy {
    function plan(address, bytes calldata params) external pure override returns (IHiroWallet.Call[] memory calls) {
        if (params.length == 0) return new IHiroWallet.Call[](0);
        (address target, bytes memory data, uint256 value) = abi.decode(params, (address, bytes, uint256));
        calls = new IHiroWallet.Call[](1);
        calls[0] = IHiroWallet.Call({target: target, data: data, value: value});
    }
}
