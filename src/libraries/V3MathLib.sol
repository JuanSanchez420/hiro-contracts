// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";
import "./LiquidityAmounts.sol";
import "./TickMath.sol";

/// @title V3MathLib
/// @notice Strategy-side V3 math: liquidity↔amount conversions, swap sizing for
/// rebalances. All functions are pure and operate on V3 fixed-point sqrt prices.
library V3MathLib {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /// @notice Inputs for `getUncollectedFees`. The pool reads (`feeGrowthGlobal*`,
    /// `ticks(tickLower/tickUpper).feeGrowthOutside*`, `slot0().tick`) and position reads
    /// (`positions().feeGrowthInside*Last`, `liquidity`, `tokensOwed*`) are gathered by the
    /// caller so this library stays pure and unit-testable without a pool.
    struct FeeGrowthInputs {
        int24 tickCurrent;
        int24 tickLower;
        int24 tickUpper;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint256 feeGrowthOutsideLower0X128;
        uint256 feeGrowthOutsideLower1X128;
        uint256 feeGrowthOutsideUpper0X128;
        uint256 feeGrowthOutsideUpper1X128;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Current uncollected fees of a V3 position, including fees accrued since the
    /// last poke (which `positions().tokensOwed*` alone misses). Mirrors Uniswap's
    /// `Tick.getFeeGrowthInside` + `Position.update`.
    /// @dev Q128.128 fee-growth values overflow by design; every subtraction here relies on
    /// mod-2^256 wraparound, so the whole body is `unchecked` (same reason TickMath needs its
    /// unchecked block). Under 0.8 checked arithmetic these would revert on the common
    /// underflow case.
    function getUncollectedFees(FeeGrowthInputs memory f)
        internal
        pure
        returns (uint256 uncollected0, uint256 uncollected1)
    {
        unchecked {
            // feeGrowthBelow: outside-lower if spot is at/above the lower tick, else global − outside-lower.
            uint256 below0;
            uint256 below1;
            if (f.tickCurrent >= f.tickLower) {
                below0 = f.feeGrowthOutsideLower0X128;
                below1 = f.feeGrowthOutsideLower1X128;
            } else {
                below0 = f.feeGrowthGlobal0X128 - f.feeGrowthOutsideLower0X128;
                below1 = f.feeGrowthGlobal1X128 - f.feeGrowthOutsideLower1X128;
            }

            // feeGrowthAbove: outside-upper if spot is below the upper tick, else global − outside-upper.
            uint256 above0;
            uint256 above1;
            if (f.tickCurrent < f.tickUpper) {
                above0 = f.feeGrowthOutsideUpper0X128;
                above1 = f.feeGrowthOutsideUpper1X128;
            } else {
                above0 = f.feeGrowthGlobal0X128 - f.feeGrowthOutsideUpper0X128;
                above1 = f.feeGrowthGlobal1X128 - f.feeGrowthOutsideUpper1X128;
            }

            uint256 feeGrowthInside0 = f.feeGrowthGlobal0X128 - below0 - above0;
            uint256 feeGrowthInside1 = f.feeGrowthGlobal1X128 - below1 - above1;

            // Delta since the position's last checkpoint; intentional wrap when inside < last.
            uint256 delta0 = feeGrowthInside0 - f.feeGrowthInside0LastX128;
            uint256 delta1 = feeGrowthInside1 - f.feeGrowthInside1LastX128;

            uncollected0 = uint256(f.tokensOwed0) + FullMath.mulDiv(delta0, f.liquidity, Q128);
            uncollected1 = uint256(f.tokensOwed1) + FullMath.mulDiv(delta1, f.liquidity, Q128);
        }
    }

    /// @notice tick-overload. Resolves the two range sqrt ratios then delegates.
    function getAmountsForLiquidity(uint160 sqrtRatioX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    /// @notice tick-overload. Resolves the two range sqrt ratios then delegates.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @notice token1-value of `amount0` at the given sqrt price: amount0 × (sqrtP/2^96)².
    function valueOfToken0InToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    /// @notice token0-value of `amount1` at the given sqrt price: amount1 × (2^96/sqrtP)².
    function valueOfToken1InToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// @notice Returns (zeroForOne, amountIn) for the swap that rebalances `walletAmt0` / `walletAmt1`
    /// to match the token ratio implied by the new range at the current sqrt price.
    /// @dev Caller must ensure currentTick is strictly inside (sqrtLowerX96, sqrtUpperX96).
    function computeOptimalSwap(
        uint256 walletAmt0,
        uint256 walletAmt1,
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal pure returns (bool zeroForOne, uint256 amountIn) {
        (uint256 refAmt0, uint256 refAmt1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, uint128(Q96));

        uint256 refValue0InToken1 = valueOfToken0InToken1(refAmt0, sqrtPriceX96);
        uint256 totalRefValue = refValue0InToken1 + refAmt1;
        if (totalRefValue == 0) {
            return (false, 0);
        }

        uint256 walletValueInToken1 = walletAmt1 + valueOfToken0InToken1(walletAmt0, sqrtPriceX96);
        uint256 targetValue0InToken1 = FullMath.mulDiv(walletValueInToken1, refValue0InToken1, totalRefValue);
        uint256 targetAmt0 = valueOfToken1InToken0(targetValue0InToken1, sqrtPriceX96);

        if (walletAmt0 > targetAmt0) {
            return (true, walletAmt0 - targetAmt0);
        }
        uint256 targetAmt1 = walletValueInToken1 - targetValue0InToken1;
        return (false, walletAmt1 > targetAmt1 ? walletAmt1 - targetAmt1 : 0);
    }
}
