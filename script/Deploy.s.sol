// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Script, console} from "forge-std/Script.sol";
import {Hiro} from "../src/Hiro.sol";
import {HiroFactory} from "../src/HiroFactory.sol";

contract Deploy is Script {
    address public hiro;
    HiroFactory public hiroFactory;

    int24 public constant MAX_TICK = 887220;
    int24 public constant MIN_TICK = -MAX_TICK;

    address public weth = vm.envAddress("WETH");

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("../data/whitelist.json");

        address[] memory initialWhitelist = abi.decode(vm.parseJson(json), (address[]));

        vm.startBroadcast();

        hiro = new Hiro();

        hiroFactory = new HiroFactory(
            hiro,
            vm.envAddress("AGENT_ADDRESS"),
            100 ether,
            initialWhitelist
        );

        ICLFactory factory = ICLFactory(
            vm.envAddress("AERO_FACTORY")
        );

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );

        address pool = factory.createPool(token0, token1, fee, vm.envString("STARTING_PRICE"));
        console.log("Pool created at:", pool);
        
        seedPool(positionManager);

        vm.stopBroadcast();
    }

    function seedPool(INonfungiblePositionManager positionManager) internal {
        uint256 tokenAmount = 500_000_000 ether;

        (address token0, address token1) = weth < hiro
            ? (weth, hiro)
            : (hiro, weth);
        (uint256 amount0, uint256 amount1) = weth < hiro
            ? (tokenAmount, 0)
            : (0, tokenAmount);

        IERC20(token0).approve(address(positionManager), tokenAmount);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: msg.sender,
                deadline: block.timestamp + 120 // 2-minute deadline
            });

        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = positionManager.mint(params);

        console.log("Liquidity added:");
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", liquidity);
        console.log("  Amount0 used:", amount0);
        console.log("  Amount1 used:", amount1);
    }
}
