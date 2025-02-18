// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";

contract HiroWalletTest is Test {
    HiroWallet public hiroWallet;

    function setUp() public {
        hiroWallet = new HiroWallet(
            address(this),
            address(this)
        );

    }

    function test_HiroWallet_details() public view {
        assertEq(hiroWallet.owner(), address(this));
        assertEq(hiroWallet.tokenAddress(), address(this));
    }
}