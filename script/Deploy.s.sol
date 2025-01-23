// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {Hiro} from "../src/Hiro.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";

contract Deploy is Script {
    Hiro public hiro;
    HiroFactory public hiroFactory;

    int24 public constant MAX_TICK = 887220;
    int24 public constant MIN_TICK = -MAX_TICK;
    uint24 public constant fee = 3000;
    int24 public constant tickSpacing = 200;

    address public weth = vm.envAddress("WETH");

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("./script/whitelist.json");

        address[] memory initialWhitelist = abi.decode(
            vm.parseJson(json),
            (address[])
        );

        vm.startBroadcast();

        hiro = new Hiro();
        console.log("Hiro deployed at:", address(hiro));

        hiroFactory = new HiroFactory(
            address(hiro),
            vm.envAddress("AGENT_ADDRESS"),
            100 ether,
            initialWhitelist
        );

        ICLFactory factory = ICLFactory(vm.envAddress("AERO_FACTORY"));

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );
/*
        address pool = factory.createPool(
            address(hiro),
            weth,
            tickSpacing,
            TickMath.getSqrtRatioAtTick(int24(vm.envInt("STARTING_TICK")))
        );
        console.log("Pool created at:", pool);
        
        */

/*
        (
            uint160 sqrtPriceX96,
            int24 tick,
            ,
            ,
            ,
            uint8 feeProtocol,
            bool unlocked
        ) = IUniswapV3PoolState(pool).slot0();

        console.log("sqrtPriceX96", uint256(sqrtPriceX96));
        console.log("tick:", int256(tick));
        console.log("fee:", uint256(feeProtocol));
        console.log("unlocked:", unlocked);

*/
/*
        uint256 l = IUniswapV3PoolState(pool).liquidity();
        console.log("liquidity:", l);

        int24 t = IUniswapV3PoolImmutables(pool).tickSpacing();
        console.log("tickSpacing:", int256(t));
*/
        seedPool(positionManager);

        vm.stopBroadcast();
    }

    function seedPool(INonfungiblePositionManager positionManager) internal {
        uint256 tokenAmount = 500_000_000 ether;

        bool wethIsToken0 = weth < address(hiro);

        (address token0, address token1) = wethIsToken0
            ? (weth, address(hiro))
            : (address(hiro), weth);
        (uint256 amount0Desired, uint256 amount1Desired) = wethIsToken0
            ? (uint256(0), tokenAmount)
            : (tokenAmount, uint256(0));

        address tokenToApprove = wethIsToken0 ? address(hiro) : weth;

        IERC20(tokenToApprove).approve(address(positionManager), tokenAmount);

        int24 startingTick = int24(vm.envInt("STARTING_TICK"));
        int24 tickUpper = nearestUsableTick(wethIsToken0 ? MAX_TICK : startingTick);
        int24 tickLower = nearestUsableTick(wethIsToken0 ? startingTick : MIN_TICK);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: msg.sender,
                deadline: block.timestamp + 120, // 2-minute deadline
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(int24(vm.envInt("STARTING_TICK")))
            });

        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = positionManager.mint(params);

        console.log("Liquidity added:");
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", uint256(liquidity));
        console.log("  Amount0 used:", amount0);
        console.log("  Amount1 used:", amount1);
    }

    function nearestUsableTick(int24 tick) internal view returns (int24) {
        return (tick / tickSpacing) * tickSpacing;
    }
}
