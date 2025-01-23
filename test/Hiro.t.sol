// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

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
        assertEq(hiro.decimals(), 18);
    }
}