// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";
import "lib/slipstream/contracts/core/interfaces/ICLFactory.sol";
import "lib/slipstream/contracts/core/interfaces/ICLPool.sol";
import "lib/slipstream/contracts/periphery/interfaces/ISwapRouter.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract TestHiroWallet is Test {
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;
    uint256 public constant PURCHASE_PRICE = 10_000_000_000_000_000;

    address user = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address notOwner = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    address public weth = vm.envAddress("WETH");
    address public router = vm.envAddress("AERO_ROUTER");

    receive() external payable {}

    function setUp() public {
        uint256 forkId = vm.createFork("http://localhost:8545");
        vm.selectFork(forkId);

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

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );

        hiroFactory = new HiroFactory(30_000, user, initialWhitelist, agents);
        console.log("Hiro Factory deployed at:", address(hiroFactory));

        vm.startPrank(user);

        hiroWallet = HiroWallet(
            payable(
                hiroFactory.createHiroWallet{
                    value: hiroFactory.purchasePrice() * 2
                }()
            )
        );

        vm.stopPrank();
    }

    function test_details() public view {
        console.log("user:", user);
        console.log("msg.sender:", msg.sender);
        console.log("HiroWallet owner:", hiroWallet.owner());
        console.log("HiroWallet factory:", hiroWallet.factory());
    }

    function test_deposit_ETH() public payable {
        uint256 depositAmount = 2 * PURCHASE_PRICE;
        uint256 walletBalanceBefore = address(hiroWallet).balance;

        vm.startPrank(user);
        address(hiroWallet).call{value: depositAmount}("");

        uint256 walletBalanceAfter = address(hiroWallet).balance;
        vm.stopPrank();

        assertEq(walletBalanceAfter, walletBalanceBefore + depositAmount);
    }

    function test_deposit_ETH_nonOwner() public payable {
        uint256 depositAmount = 2 * PURCHASE_PRICE;
        vm.startPrank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner", notOwner);
        address(hiroWallet).call{value: depositAmount}("");
    }

    // Test withdraw: Owner withdraws tokens from the wallet.
    function test_withdraw() public {
        vm.startPrank(user);

        // send ether to the wallet
        address(hiroWallet).call{value: 1 ether}("");

        // wrap the ether to get a token balance
        bytes memory callData = abi.encodeWithSignature("deposit()");
        hiroWallet.execute(weth, callData, 1 ether);

        uint256 ownerBalanceBefore = IERC20(weth).balanceOf(user);

        // use the withdraw function to get the ether back
        hiroWallet.withdraw(weth, 1 ether);
        uint256 ownerBalanceAfter = IERC20(weth).balanceOf(user);
        vm.stopPrank();

        assertEq(ownerBalanceAfter, ownerBalanceBefore + 1 ether);
    }

    // Test execute: Only an agent can call execute.
    function test_execute_asAgent() public {
        address agent = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

        bool isAgent = hiroFactory.isAgent(agent);
        assertTrue(isAgent);

        vm.startPrank(agent);
        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            user,
            1
        );

        uint256 fee = hiroWallet.execute(weth, callData, 0);

        vm.stopPrank();

        // Verify that some result is returned (or simply that the call didn't revert).
        assertTrue(fee >= 0);
    }

    // Test execute: Non-agent calls should revert.
    function test_execute_fail_forNonAgent() public {
        address nonAgent = vm.addr(2);
        bytes memory callData = abi.encodeWithSignature("deposit()");

        address(hiroWallet).call{value: 1 ether}("");

        vm.prank(nonAgent);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(weth, callData, 1 ether);
    }

    function test_wrapsETH() public {
        address agent = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

        vm.startPrank(user);
        address(hiroWallet).call{value: 1 ether}("");
        assertTrue(address(hiroWallet).balance > 0);
        vm.stopPrank();

        vm.startPrank(agent);

        uint256 balanceBefore = IERC20(weth).balanceOf(address(hiroWallet));

        bytes memory callData = abi.encodeWithSignature("deposit()");

        uint256 fee = hiroWallet.execute(weth, callData, 1 ether);

        uint256 balanceAfter = IERC20(weth).balanceOf(address(hiroWallet));

        vm.stopPrank();

        assertTrue(balanceAfter > balanceBefore);
    }

    function swapETHForUSDC(
        address recipient,
        uint256 ethAmount
    ) internal returns (uint256) {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

        // Create the swap path: ETH → WETH → USDC
        bytes memory path = abi.encodePacked(weth, uint24(100), usdc);

        // Set up the parameters for the swap
        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: recipient,
                deadline: block.timestamp + 15 minutes,
                amountIn: ethAmount,
                amountOutMinimum: 0
            });

        uint256 amountOut = ISwapRouter(router).exactInput{value: ethAmount}(
            params
        );

        return amountOut;
    }

    function testAddLiquidityWETHUSDC() public {
        address agent = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC mainnet address
        address nonFungiblePositionManager = 0x827922686190790b37229fd06084350E74485b72;

        // Setup: Ensure wallet has WETH and USDC tokens
        vm.deal(address(hiroWallet), 10 ether);

        // Convert some ETH to WETH for the wallet
        vm.startPrank(agent);
        bytes memory depositCallData = abi.encodeWithSignature("deposit()");
        hiroWallet.execute(address(weth), depositCallData, 2 ether);
        vm.stopPrank();

        // Give the wallet some USDC
        uint256 usdcAmount = swapETHForUSDC(address(hiroWallet), 2 ether);

        // Approve NPM to use tokens from wallet
        vm.startPrank(user);
        bytes memory wethApproveCallData = abi.encodeWithSignature(
            "approve(address,uint256)",
            address(nonFungiblePositionManager),
            2 ether
        );

        bytes memory usdcApproveCallData = abi.encodeWithSignature(
            "approve(address,uint256)",
            address(nonFungiblePositionManager),
            usdcAmount
        );

        hiroWallet.execute(address(weth), wethApproveCallData, 0);
        hiroWallet.execute(usdc, usdcApproveCallData, 0);
        vm.stopPrank();

        // Setup agent to call execute
        vm.startPrank(agent);

        // Define token order
        address token0 = usdc < address(weth) ? usdc : address(weth);
        address token1 = usdc < address(weth) ? address(weth) : usdc;

        // For full range liquidity in V3, we need to set tickLower and tickUpper to min/max values
        int24 tickSpacing = 100;
        int24 minTick = -887272; // Minimum tick for full range (based on 0.3% fee tier)
        int24 maxTick = 887272; // Maximum tick for full range (based on 0.3% fee tier)

        // Ensure ticks are multiples of the spacing
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        // Params for adding liquidity
        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: tickSpacing,
                tickLower: minTick,
                tickUpper: maxTick,
                amount0Desired: token0 == usdc ? usdcAmount : 1 ether,
                amount1Desired: token1 == usdc ? usdcAmount : 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(hiroWallet),
                deadline: block.timestamp + 15 minutes,
                sqrtPriceX96: 0
            });

        bytes memory mintCallData = abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector,
            params
        );

        // Execute the add liquidity call
        uint256 fee = hiroWallet.execute(
            address(nonFungiblePositionManager),
            mintCallData,
            0
        );

        vm.stopPrank();

        // Verify position was created
        uint256 balanceOfNFTs = IERC721(address(nonFungiblePositionManager))
            .balanceOf(address(hiroWallet));

        assertEq(
            balanceOfNFTs,
            1,
            "Wallet should have received 1 position NFT"
        );
    }
}
