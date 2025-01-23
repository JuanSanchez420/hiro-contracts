// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";

import {Hiro} from "../src/Hiro.sol";

contract HiroTest is Test {
    Hiro public hiro;

    function setUp() public {
        hiro = new Hiro();
    }

    function test_Hiro_details() public view {
        assertEq(hiro.symbol(), "HIRO");
        assertEq(hiro.name(), "Hiro Token");
        assertEq(uint256(hiro.decimals()), uint256(18));
    }
}