// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Implements the surface the strategies read: `slot0()`, `tickSpacing()`, and (for
/// UniV3AutoCompoundStrategy) `feeGrowthGlobal0/1X128()` + `ticks()`. Does not inherit
/// IUniswapV3Pool (which carries dozens of methods we don't need).
contract MockUniswapV3Pool {
    uint160 public sqrtPriceX96Stored;
    int24 public tickStored;
    int24 public tickSpacingStored;

    uint256 public feeGrowthGlobal0X128Stored;
    uint256 public feeGrowthGlobal1X128Stored;

    struct TickInfo {
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) public tickInfo;

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

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96Stored = _sqrtPriceX96;
        tickStored = _tick;
    }

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128Stored = fg0;
        feeGrowthGlobal1X128Stored = fg1;
    }

    function setTick(int24 tick, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128) external {
        tickInfo[tick] = TickInfo(feeGrowthOutside0X128, feeGrowthOutside1X128);
    }

    function feeGrowthGlobal0X128() external view returns (uint256) {
        return feeGrowthGlobal0X128Stored;
    }

    function feeGrowthGlobal1X128() external view returns (uint256) {
        return feeGrowthGlobal1X128Stored;
    }

    function ticks(int24 tick)
        external
        view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        TickInfo memory t = tickInfo[tick];
        return (0, 0, t.feeGrowthOutside0X128, t.feeGrowthOutside1X128, 0, 0, 0, false);
    }
}
