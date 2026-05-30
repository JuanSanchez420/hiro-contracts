// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Implements only the surface UniV3RebalanceStrategy reads: `slot0()` + `tickSpacing()`.
/// Does not inherit IUniswapV3Pool (which carries dozens of methods we don't need).
contract MockUniswapV3Pool {
    uint160 public sqrtPriceX96Stored;
    int24 public tickStored;
    int24 public tickSpacingStored;

    constructor(uint160 _sqrtPriceX96, int24 _tick, int24 _tickSpacing) {
        sqrtPriceX96Stored = _sqrtPriceX96;
        tickStored = _tick;
        tickSpacingStored = _tickSpacing;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96Stored, tickStored, 0, 0, 0, 0, true);
    }

    function tickSpacing() external view returns (int24) {
        return tickSpacingStored;
    }
}
