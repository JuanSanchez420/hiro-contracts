// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HiroSeason} from "../../src/HiroSeason.sol";

/// @title HiroSeasonHarness
/// @notice Test-only contract that inherits HiroSeason and exposes its internal pure-math chains
/// for direct unit testing. The harness stubs `_getTWAPSqrtPrice` and `_getCurrentSqrtPrice` so
/// tests can drive the math without needing a live Uniswap pool.
contract HiroSeasonHarness is HiroSeason {
    uint160 internal _stubSqrt;

    constructor(address weth, address positionManager, address swapRouter)
        HiroSeason(weth, positionManager, swapRouter)
    {}

    function setHiroIsToken0ForTest(bool b) external {
        hiroIsToken0 = b;
    }

    function setStubSqrtPrice(uint160 sqrtPriceX96) external {
        _stubSqrt = sqrtPriceX96;
    }

    function _getTWAPSqrtPrice() internal view override returns (uint160) {
        return _stubSqrt;
    }

    function _getCurrentSqrtPrice() internal view override returns (uint160) {
        return _stubSqrt;
    }

    function exposeCalculateExpectedHiro(uint256 wethAmount, uint160 sqrtPriceX96, bool _hiroIsToken0)
        external
        returns (uint256)
    {
        _stubSqrt = sqrtPriceX96;
        hiroIsToken0 = _hiroIsToken0;
        return _calculateExpectedHiro(wethAmount);
    }

    function exposeCalculatePriceLimit(uint160 sqrtPriceX96, uint256 _priceImpactBps, bool _hiroIsToken0)
        external
        returns (uint160)
    {
        _stubSqrt = sqrtPriceX96;
        hiroIsToken0 = _hiroIsToken0;
        priceImpactBps = _priceImpactBps;
        return _calculatePriceLimit();
    }

    function exposeGetCurrentHiroPrice(uint160 sqrtPriceX96, bool _hiroIsToken0) external returns (uint256) {
        _stubSqrt = sqrtPriceX96;
        hiroIsToken0 = _hiroIsToken0;
        // getCurrentHiroPrice early-returns 0 when pool is unset; seed it to any non-zero address.
        if (pool == address(0)) pool = address(0xdead);
        return this.getCurrentHiroPrice();
    }
}
