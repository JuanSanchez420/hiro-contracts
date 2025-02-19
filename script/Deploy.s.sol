// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {Hiro} from "../src/Hiro.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";
import "lib/slipstream/contracts/core/interfaces/ICLFactory.sol";

contract Deploy is Script {
    Hiro public hiro;
    HiroFactory public hiroFactory;

    int24 public constant MAX_TICK = 887220;
    int24 public constant MIN_TICK = -MAX_TICK;
    uint24 public constant fee = 3000;
    int24 public constant tickSpacing = 200;

    uint256 tokenAmount = 500_000_000 ether;

    address public weth = vm.envAddress("WETH");

    function setUp() public {}

    function run() public {
        string memory json = vm.readFile("./script/whitelist.json");

        address[] memory initialWhitelist = abi.decode(
            vm.parseJson(json),
            (address[])
        );

        // Build dynamic agents array by looking for AGENT_ADDRESS_1, AGENT_ADDRESS_2, etc.
        uint256 maxAgents = 5; // adjust as needed
        address[] memory agentsTemp = new address[](maxAgents);
        uint256 count = 0;
        for (uint256 i = 1; i <= maxAgents; i++) {
            string memory key = string(
                abi.encodePacked("AGENT_ADDRESS_", vm.toString(i))
            );
            // If the environment variable isn’t set, vm.envString returns an empty string.
            string memory agentStr = vm.envString(key);
            if (bytes(agentStr).length == 0) {
                break;
            }
            agentsTemp[count] = vm.envAddress(key);
            count++;
        }
        // Copy found addresses into a dynamic array of exact length.
        address[] memory agents = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            agents[i] = agentsTemp[i];
        }

        vm.startBroadcast();

        hiro = new Hiro();
        hiro.transfer(msg.sender, hiro.balanceOf(address(this)));
        console.log("Hiro tokens transferred to deployer");
        console.log("Hiro deployed at:", address(hiro));

        hiroFactory = new HiroFactory(
            address(hiro),
            100 ether,
            msg.sender,
            initialWhitelist,
            agents
        );
        console.log("Hiro Factory deployed at:", address(hiroFactory));

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );

        seedPool(positionManager);

        vm.stopBroadcast();
    }

    function seedPool(INonfungiblePositionManager positionManager) internal {
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

        int24 tickUpper = nearestUsableTick(
            wethIsToken0 ? startingTick : MAX_TICK
        );
        int24 tickLower = nearestUsableTick(
            wethIsToken0 ? MIN_TICK : startingTick
        );

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
                sqrtPriceX96: TickMath.getSqrtRatioAtTick(startingTick)
            });

        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = positionManager.mint(params);

        address pool = ICLFactory(positionManager.factory()).getPool(
            token0,
            token1,
            tickSpacing
        );

        console.log("Liquidity added to:", pool);
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", uint256(liquidity));
        console.log("  Amount0 used:", amount0);
        console.log("  Amount1 used:", amount1);
    }

    function nearestUsableTick(int24 tick) internal pure returns (int24) {
        return (tick / tickSpacing) * tickSpacing;
    }
}
