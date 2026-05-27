// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HiroSeasonHarness} from "./harness/HiroSeasonHarness.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @title HiroSeasonMathTest
/// @notice Drives HiroSeason's internal math chains directly via the harness, no Base fork required.
contract HiroSeasonMathTest is Test {
    HiroSeasonHarness internal h;

    uint160 internal constant Q96 = uint160(uint256(1) << 96);

    function setUp() public {
        // Dummy addresses; the math under test never touches the pool/router/WETH.
        h = new HiroSeasonHarness(address(0xdead), address(0xbeef), address(0xcafe));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // _calculateExpectedHiro
    // ═══════════════════════════════════════════════════════════════════════════

    function test_expectedHiro_token0_priceOne() public {
        // sqrtPrice = 2^96 → price = 1, so HIRO out == WETH in for either branch.
        assertEq(h.exposeCalculateExpectedHiro(1 ether, Q96, true), 1 ether);
    }

    function test_expectedHiro_token1_priceOne() public {
        assertEq(h.exposeCalculateExpectedHiro(1 ether, Q96, false), 1 ether);
    }

    function test_expectedHiro_token0_priceFour() public {
        // sqrtPrice = 2*Q96 → price = 4 (HIRO is cheaper since HIRO=token0, WETH=token1).
        // token0 branch: HIRO = WETH * Q192 / sqrt^2 = WETH / 4
        uint160 sqrt = uint160(2 * uint256(Q96));
        assertEq(h.exposeCalculateExpectedHiro(4 ether, sqrt, true), 1 ether);
    }

    function test_expectedHiro_token1_priceFour() public {
        // token1 branch: HIRO = WETH * sqrt^2 / Q192 = WETH * 4
        uint160 sqrt = uint160(2 * uint256(Q96));
        assertEq(h.exposeCalculateExpectedHiro(1 ether, sqrt, false), 4 ether);
    }

    function test_expectedHiro_token0_zero_input_isZero() public {
        assertEq(h.exposeCalculateExpectedHiro(0, Q96, true), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // _calculatePriceLimit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_priceLimit_token0_typical() public {
        // sqrtPrice=Q96, impact=200bps (2%). adjusted = Q96 * (10000 + 100) / 10000 = Q96 * 10100/10000.
        uint160 got = h.exposeCalculatePriceLimit(Q96, 200, true);
        uint256 expected = uint256(Q96) * (10000 + 200 / 2) / 10000;
        assertEq(uint256(got), expected);
        assertGt(uint256(got), uint256(Q96)); // moves up
    }

    function test_priceLimit_token1_typical() public {
        uint160 got = h.exposeCalculatePriceLimit(Q96, 200, false);
        uint256 expected = uint256(Q96) * (10000 - 200 / 2) / 10000;
        assertEq(uint256(got), expected);
        assertLt(uint256(got), uint256(Q96)); // moves down
    }

    function test_priceLimit_token0_clampsToMaxMinusOne() public {
        // Use a sqrtPrice close to MAX_SQRT_RATIO so any positive impact pushes adjusted >= MAX.
        uint160 nearMax = uint160(TickMath.MAX_SQRT_RATIO - 1);
        uint160 got = h.exposeCalculatePriceLimit(nearMax, 1000, true); // 10% impact
        assertEq(uint256(got), uint256(TickMath.MAX_SQRT_RATIO) - 1);
    }

    function test_priceLimit_token1_clampsToMinPlusOne() public {
        // sqrtPrice == MIN_SQRT_RATIO → adjusted = MIN * 9950 / 10000 < MIN → clamp.
        uint160 got = h.exposeCalculatePriceLimit(TickMath.MIN_SQRT_RATIO, 100, false);
        assertEq(uint256(got), uint256(TickMath.MIN_SQRT_RATIO) + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // getCurrentHiroPrice
    // ═══════════════════════════════════════════════════════════════════════════

    function test_currentHiroPrice_token0_priceOne() public {
        // sqrt=Q96 → 1 WETH yields 1e18 of HIRO regardless of branch.
        assertEq(h.exposeGetCurrentHiroPrice(Q96, true), 1e18);
    }

    function test_currentHiroPrice_token1_priceOne() public {
        assertEq(h.exposeGetCurrentHiroPrice(Q96, false), 1e18);
    }

    function test_currentHiroPrice_token0_priceFour() public {
        uint160 sqrt = uint160(2 * uint256(Q96));
        // token0 (HIRO is cheaper): 1 WETH = 0.25 HIRO
        assertEq(h.exposeGetCurrentHiroPrice(sqrt, true), 0.25 ether);
    }

    function test_currentHiroPrice_token1_priceFour() public {
        uint160 sqrt = uint160(2 * uint256(Q96));
        // token1 (HIRO is more expensive): 1 WETH = 4 HIRO
        assertEq(h.exposeGetCurrentHiroPrice(sqrt, false), 4 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Redemption-share math via calculateRedemption (view; same formula as redeem())
    // ═══════════════════════════════════════════════════════════════════════════

    function test_calculateRedemption_returnsZeroBeforeRedeemable() public view {
        // Default state is SETUP; calculateRedemption returns 0.
        assertEq(h.calculateRedemption(1), 0);
    }

    function test_calculateRedemption_proportional() public {
        _seedRedemption(1_000_000 ether, 10 ether); // 1M HIRO, 10 ETH

        assertEq(h.calculateRedemption(0), 0);
        assertEq(h.calculateRedemption(1), 0); // rounds down
        assertEq(h.calculateRedemption(100_000 ether), 1 ether); // 10%
        assertEq(h.calculateRedemption(1_000_000 ether), 10 ether); // full pool
    }

    function test_calculateRedemption_midpoint() public {
        _seedRedemption(2 ether, 6 ether);
        // Mid: 1 HIRO of 2 total → half the pool
        assertEq(h.calculateRedemption(1 ether), 3 ether);
    }

    /// @dev Force-set state + redemption snapshot via vm.store so we can call calculateRedemption
    /// without driving the full season lifecycle (which would require Base-fork integration).
    /// Storage layout (Ownable + ReentrancyGuard occupy the first two slots):
    ///   slot 2: SeasonState state (uint8) + address pool (packed)
    ///   slot 6: uint256 totalRedemptionWETH
    ///   slot 7: uint256 totalRedeemableHiro
    function _seedRedemption(uint256 totalHiro, uint256 totalEth) internal {
        // Read-modify-write the packed slot so we don't clobber `pool` when overwriting `state`.
        bytes32 slot2 = vm.load(address(h), bytes32(uint256(2)));
        bytes32 newSlot2 = (slot2 & ~bytes32(uint256(0xff))) | bytes32(uint256(3)); // REDEEMABLE
        vm.store(address(h), bytes32(uint256(2)), newSlot2);
        vm.store(address(h), bytes32(uint256(6)), bytes32(totalEth));
        vm.store(address(h), bytes32(uint256(7)), bytes32(totalHiro));
    }
}
