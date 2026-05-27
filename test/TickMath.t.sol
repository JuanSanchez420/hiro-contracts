// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

contract TickMathCaller {
    function call(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }
}

contract TickMathTest is Test {
    int24[] internal ticks;
    uint256[] internal expected;
    TickMathCaller internal caller;

    function setUp() public {
        caller = new TickMathCaller();
        string memory csv = vm.readFile("./test/fixtures/tickmath_golden.csv");
        string[] memory lines = vm.split(csv, "\n");
        for (uint256 i = 0; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;
            string[] memory parts = vm.split(lines[i], ",");
            ticks.push(int24(vm.parseInt(parts[0])));
            expected.push(vm.parseUint(parts[1]));
        }
    }

    function test_getSqrtRatioAtTick_parity() public view {
        for (uint256 i = 0; i < ticks.length; i++) {
            uint160 got = TickMath.getSqrtRatioAtTick(ticks[i]);
            assertEq(uint256(got), expected[i], "sqrt ratio mismatch");
        }
    }

    function test_revertsOutOfRange_positive() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        caller.call(int24(887273));
    }

    function test_revertsOutOfRange_negative() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        caller.call(int24(-887273));
    }
}
