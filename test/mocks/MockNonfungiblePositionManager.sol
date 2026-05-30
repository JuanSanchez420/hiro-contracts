// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/INonfungiblePositionManager.sol";

/// @dev Minimal mock for unit-testing UniV3RebalanceStrategy.plan() guard logic.
/// Only `positions` and `ownerOf` need to be callable; everything else is a stub.
contract MockNonfungiblePositionManager {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public storedPositions;
    mapping(uint256 => address) public storedOwners;
    mapping(uint256 => uint256) public feeGrowthInside0Last;
    mapping(uint256 => uint256) public feeGrowthInside1Last;

    function setPosition(
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) external {
        storedPositions[tokenId] = Position({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });
    }

    function setOwner(uint256 tokenId, address owner) external {
        storedOwners[tokenId] = owner;
    }

    function setFeeGrowthInsideLast(uint256 tokenId, uint256 fg0Last, uint256 fg1Last) external {
        feeGrowthInside0Last[tokenId] = fg0Last;
        feeGrowthInside1Last[tokenId] = fg1Last;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        // Named returns (assigned incrementally) avoid a 12-value tuple expression that
        // would otherwise blow the stack once the fee-growth mapping reads are added.
        Position memory pos = storedPositions[tokenId];
        token0 = pos.token0;
        token1 = pos.token1;
        fee = pos.fee;
        tickLower = pos.tickLower;
        tickUpper = pos.tickUpper;
        liquidity = pos.liquidity;
        feeGrowthInside0LastX128 = feeGrowthInside0Last[tokenId];
        feeGrowthInside1LastX128 = feeGrowthInside1Last[tokenId];
        tokensOwed0 = pos.tokensOwed0;
        tokensOwed1 = pos.tokensOwed1;
        // nonce, operator stay zero
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return storedOwners[tokenId];
    }
}
