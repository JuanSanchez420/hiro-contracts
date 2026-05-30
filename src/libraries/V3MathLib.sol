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
