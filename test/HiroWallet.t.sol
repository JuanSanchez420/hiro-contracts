// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {HiroWallet} from "../src/HiroWallet.sol";
import {HiroFactory} from "../src/HiroFactory.sol";
import {Hiro} from "../src/Hiro.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/slipstream/contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import "lib/slipstream/contracts/core/libraries/TickMath.sol";
import "lib/slipstream/contracts/core/interfaces/ICLFactory.sol";
import "lib/slipstream/contracts/core/interfaces/ICLPool.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract TestHiroWallet is Test {
    Hiro public hiro;
    HiroFactory public hiroFactory;
    HiroWallet public hiroWallet;
    uint256 public constant PURCHASE_PRICE = 10_000_000_000_000_000;
    uint256 public hiroBalance;
    address public pool;

    address user = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address notOwner = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    struct PoolParams {
        bool wethIsToken0;
        address token0;
        address token1;
        uint256 amount0Desired;
        uint256 amount1Desired;
        address tokenToApprove;
        int24 tickLower;
        int24 tickUpper;
    }

    int24 public constant MAX_TICK = 887220;
    int24 public constant MIN_TICK = -MAX_TICK;
    uint24 public constant fee = 3000;
    int24 public constant tickSpacing = 200;

    uint256 tokensForLiquidity = 500_000_000 ether;

    address public weth = vm.envAddress("WETH");
    address public router = vm.envAddress("AERO_ROUTER");
    int24 startingTick = int24(vm.envInt("STARTING_TICK"));

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

        hiro = new Hiro();
        console.log("Hiro deployed at:", address(hiro));

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(
                vm.envAddress("AERO_NONFUNGIBLEPOSITIONMANAGER")
            );

        pool = seedPool(positionManager);

        hiroFactory = new HiroFactory(
            address(hiro),
            pool,
            weth,
            router,
            10_000,
            user,
            initialWhitelist,
            agents
        );
        console.log("Hiro Factory deployed at:", address(hiroFactory));

        vm.startPrank(user);

        // Whitelist the hiro contract for use later
        hiroFactory.addToWhitelist(address(hiro));

        hiroWallet = HiroWallet(
            payable(
                hiroFactory.createHiroWallet{
                    value: hiroFactory.purchasePrice()
                }(0)
            )
        );

        console.log("Hiro price before:", hiroWallet.getTokenPrice());
        hiroBalance = hiroFactory.swapETHForHiro{value: PURCHASE_PRICE}(
            0,
            user
        );
        console.log("1 ETH swapped for Hiro:", hiroBalance);
        console.log("Hiro price after:", hiroWallet.getTokenPrice());
        vm.stopPrank();
    }

    function seedPool(
        INonfungiblePositionManager positionManager
    ) internal returns (address) {
        PoolParams memory params = createPoolParams();

        IERC20(params.tokenToApprove).approve(
            address(positionManager),
            tokensForLiquidity
        );

        INonfungiblePositionManager.MintParams
            memory mintParams = INonfungiblePositionManager.MintParams({
                token0: params.token0,
                token1: params.token1,
                tickSpacing: tickSpacing,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
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
        ) = positionManager.mint(mintParams);

        address pool = ICLFactory(positionManager.factory()).getPool(
            params.token0,
            params.token1,
            tickSpacing
        );

        console.log("Pool deployed at:", pool);

        printResults(tokenId, liquidity, amount0, amount1);

        return pool;
    }

    function nearestUsableTick(int24 tick) internal pure returns (int24) {
        return (tick / tickSpacing) * tickSpacing;
    }

    function createPoolParams()
        internal
        view
        returns (PoolParams memory params)
    {
        params.wethIsToken0 = weth < address(hiro);

        if (params.wethIsToken0) {
            params.token0 = weth;
            params.token1 = address(hiro);
            params.amount0Desired = 0;
            params.amount1Desired = tokensForLiquidity;
            params.tokenToApprove = address(hiro);
            params.tickUpper = nearestUsableTick(startingTick);
            params.tickLower = nearestUsableTick(MIN_TICK);
        } else {
            params.token0 = address(hiro);
            params.token1 = weth;
            params.amount0Desired = tokensForLiquidity;
            params.amount1Desired = 0;
            params.tokenToApprove = weth;
            params.tickUpper = nearestUsableTick(MAX_TICK);
            params.tickLower = nearestUsableTick(startingTick);
        }
    }

    function printResults(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) public pure {
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", uint256(liquidity));
        console.log("Amount0 used:", amount0);
        console.log("Amount1 used:", amount1);
    }

    function test_details() public view {
        console.log("user:", user);
        console.log("msg.sender:", msg.sender);
        console.log("HiroWallet owner:", hiroWallet.owner());
        console.log("HiroWallet factory:", hiroWallet.factory());
        console.log("HiroWallet hiro:", hiroWallet.hiro());
        console.log("User Hiro", hiro.balanceOf(user));
        console.log("HiroWallet pool:", hiroWallet.pool());
        console.log("HiroWallet weth:", hiroWallet.weth());
        console.log("Weth is token0:", weth < address(hiro));
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

    // Test deposit: Only the owner should be allowed to deposit tokens.
    function test_deposit() public {
        vm.startPrank(user);
        console.log("user balance:", hiro.balanceOf(user));
        hiro.approve(address(hiroWallet), hiroBalance);

        uint256 walletBalanceBefore = hiro.balanceOf(address(hiroWallet));

        hiroWallet.deposit(address(hiro), hiroBalance);
        uint256 walletBalanceAfter = hiro.balanceOf(address(hiroWallet));
        vm.stopPrank();

        assertEq(walletBalanceAfter, walletBalanceBefore + hiroBalance);
    }

    // Test withdraw: Owner withdraws tokens from the wallet.
    function test_withdraw() public {
        vm.startPrank(user);

        hiro.approve(address(hiroWallet), hiroBalance);

        hiroWallet.deposit(address(hiro), hiroBalance);

        uint256 ownerBalanceBefore = hiro.balanceOf(user);

        hiroWallet.withdraw(address(hiro), hiroBalance);
        uint256 ownerBalanceAfter = hiro.balanceOf(user);
        vm.stopPrank();

        assertEq(ownerBalanceAfter, ownerBalanceBefore + hiroBalance);
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

        uint256 fee = hiroWallet.execute(address(hiro), callData, 0);

        vm.stopPrank();

        // Verify that some result is returned (or simply that the call didn't revert).
        assertTrue(fee >= 0);
    }

    // Test execute: Non-agent calls should revert.
    function test_execute_fail_forNonAgent() public {
        address nonAgent = vm.addr(2);
        bytes memory callData = abi.encodeWithSignature(
            "printResults(uint256,uint128,uint256,uint256)",
            1,
            uint128(1000),
            10 ether,
            5 ether
        );

        vm.prank(nonAgent);
        vm.expectRevert("Not an agent");
        hiroWallet.execute(address(hiroWallet), callData, 0);
    }

    function test_number_go_up() public {
        uint256 tokenPriceBefore = hiroWallet.getTokenPrice();
        console.log("Token price before:", tokenPriceBefore);
        hiroFactory.swapETHForHiro{value: PURCHASE_PRICE}(0, msg.sender);

        uint256 tokenPriceAfter = hiroWallet.getTokenPrice();
        console.log("Token price after:", tokenPriceAfter);

        // getTokenPrice is ETH measured in Hiro tokens, so the price should go down
        assertTrue(tokenPriceAfter < tokenPriceBefore);
    }

    function test_fee_number_down_as_price_increases() public {
        address agent = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

        bool isAgent = hiroFactory.isAgent(agent);
        assertTrue(isAgent);

        vm.startPrank(agent);
        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            user,
            1
        );

        uint256 feeBeforeSwap = hiroWallet.execute(address(hiro), callData, 0);
        console.log("feeBeforeSwap:", feeBeforeSwap);

        // swap to increase price
        hiroFactory.swapETHForHiro{value: PURCHASE_PRICE}(0, msg.sender);

        uint256 feeAfterSwap = hiroWallet.execute(address(hiro), callData, 0);
        console.log("feeAfterSwap:", feeAfterSwap);

        vm.stopPrank();

        assertTrue(feeBeforeSwap > feeAfterSwap);
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

        uint256 fee = hiroWallet.execute(address(weth), callData, 1 ether);

        uint256 balanceAfter = IERC20(weth).balanceOf(address(hiroWallet));

        vm.stopPrank();

        assertTrue(balanceAfter > balanceBefore);
    }
}
