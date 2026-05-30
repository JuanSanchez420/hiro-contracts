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
        Position memory pos = storedPositions[tokenId];
        return (
            0,
            address(0),
            pos.token0,
            pos.token1,
            pos.fee,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity,
            0,
            0,
            pos.tokensOwed0,
            pos.tokensOwed1
        );
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return storedOwners[tokenId];
    }
}
