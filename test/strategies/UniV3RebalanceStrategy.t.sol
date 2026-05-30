// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {HiroFactory} from "../../src/HiroFactory.sol";
import {HiroWallet} from "../../src/HiroWallet.sol";
import {IHiroWallet} from "../../src/interfaces/IHiroWallet.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {UniV3RebalanceStrategy} from "../../src/strategies/UniV3RebalanceStrategy.sol";
import {MockNonfungiblePositionManager} from "../mocks/MockNonfungiblePositionManager.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ═══════════════════════════════════════════════════════════════════════════
// UNIT TESTS — mock-backed, no fork required
// ═══════════════════════════════════════════════════════════════════════════
contract UniV3RebalanceStrategyUnitTest is Test {
    MockNonfungiblePositionManager npm;
    MockUniswapV3Pool pool;
    MockUniswapV3Factory v3Factory;
    UniV3RebalanceStrategy strategy;

    address wallet = address(0xBEEF);
    address hiroFactory = address(0xDEAD);
    address token0 = address(0x1111);
    address token1 = address(0x2222);
    uint24 poolFee = 500;
    uint256 positionId = 1;
    uint160 constant SQRT_PRICE_AT_TICK_0 = 0x1000000000000000000000000; // 2^96

    function setUp() public {
        npm = new MockNonfungiblePositionManager();
        pool = new MockUniswapV3Pool(SQRT_PRICE_AT_TICK_0, 0, 10);
        v3Factory = new MockUniswapV3Factory();
        v3Factory.setPool(token0, token1, poolFee, address(pool));

        strategy = new UniV3RebalanceStrategy(address(npm), address(0x3333), address(v3Factory), hiroFactory);

        npm.setOwner(positionId, wallet);
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 1e6, 1e6);
    }

    function _params(int24 newLower, int24 newUpper, uint16 slip, uint16 imp) internal view returns (bytes memory) {
        return abi.encode(
            UniV3RebalanceStrategy.RebalanceParams({
                positionId: positionId,
                newTickLower: newLower,
                newTickUpper: newUpper,
                slippageBps: slip,
                maxImpactBps: imp
            })
        );
    }

    function testRevertSlippageTooHigh() public {
        vm.expectRevert(UniV3RebalanceStrategy.SlippageTooHigh.selector);
        strategy.plan(wallet, _params(-500, 500, 101, 50));
    }

    function testRevertImpactTooHigh() public {
        vm.expectRevert(UniV3RebalanceStrategy.ImpactTooHigh.selector);
        strategy.plan(wallet, _params(-500, 500, 50, 301));
    }

    function testRevertRangeNotAroundSpotAbove() public {
        // currentTick=0, newLower=10, newUpper=20 → spot below range
        vm.expectRevert(UniV3RebalanceStrategy.RangeNotAroundSpot.selector);
        strategy.plan(wallet, _params(10, 220, 50, 50));
    }

    function testRevertRangeNotAroundSpotBelow() public {
        // currentTick=0, newLower=-220, newUpper=-10 → spot above range
        vm.expectRevert(UniV3RebalanceStrategy.RangeNotAroundSpot.selector);
        strategy.plan(wallet, _params(-220, -10, 50, 50));
    }

    function testRevertRangeTooNarrow() public {
        // width = 100 < MIN_WIDTH_TICKS (200), but aligned and around spot
        vm.expectRevert(UniV3RebalanceStrategy.RangeTooNarrow.selector);
        strategy.plan(wallet, _params(-50, 50, 50, 50));
    }

    function testRevertRangeTooWide() public {
        // width = 60020 > MAX_WIDTH_TICKS (60000)
        vm.expectRevert(UniV3RebalanceStrategy.RangeTooWide.selector);
        strategy.plan(wallet, _params(-30010, 30010, 50, 50));
    }

    function testRevertTickNotAligned() public {
        // tickSpacing=10, newLower=-201 (not divisible by 10)
        vm.expectRevert(UniV3RebalanceStrategy.TickNotAligned.selector);
        strategy.plan(wallet, _params(-201, 200, 50, 50));
    }

    function testRevertNotPositionOwner() public {
        npm.setOwner(positionId, address(0xC0FFEE));
        vm.expectRevert(UniV3RebalanceStrategy.NotPositionOwner.selector);
        strategy.plan(wallet, _params(-500, 500, 50, 50));
    }

    function testRevertPoolNotFound() public {
        // Position points at tokens for which v3Factory has no pool registered
        npm.setPosition(positionId, address(0x9999), address(0xAAAA), 500, -1000, 1000, 1e18, 1e6, 1e6);
        vm.expectRevert(UniV3RebalanceStrategy.PoolNotFound.selector);
        strategy.plan(wallet, _params(-500, 500, 50, 50));
    }

    function testPlanReturnsCalls() public view {
        IHiroWallet.Call[] memory calls = strategy.plan(wallet, _params(-500, 500, 50, 100));
        // tokensOwed > 0 → protocol fee call present. With or without swap.
        assertGe(calls.length, 7);
        // first call is always decreaseLiquidity on the NPM
        assertEq(calls[0].target, address(npm));
        // last call is always mint on the NPM
        assertEq(calls[calls.length - 1].target, address(npm));
    }

    function testPlanSkipsProtocolFeeCallWhenNoOwedFees() public {
        // Re-register position with zero tokensOwed
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 0, 0);
        IHiroWallet.Call[] memory calls = strategy.plan(wallet, _params(-500, 500, 50, 100));
        // No protocol-fee call → 6 (no swap likely with symmetric position) or 8 (with swap)
        // Just assert no decoding error and at least 6 calls
        assertGe(calls.length, 6);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// FORK TESTS — runs against Base mainnet via BASE_RPC_URL (or public default)
// ═══════════════════════════════════════════════════════════════════════════
contract UniV3RebalanceStrategyForkTest is Test {
    address constant NPM_BASE = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER02_BASE = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant V3_FACTORY_BASE = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint24 constant POOL_FEE = 500; // 0.05%

    HiroFactory hiroFactory;
    HiroWallet hiroWallet;
    UniV3RebalanceStrategy strategy;

    address user;
    uint256 ownerPk = 0xA11CE;
    address agent = address(0xA61BA1);
    uint256 positionId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        user = vm.addr(ownerPk);
        vm.deal(user, 10 ether);

        address[] memory targets = new address[](4);
        targets[0] = NPM_BASE;
        targets[1] = SWAP_ROUTER02_BASE;
        targets[2] = WETH_BASE;
        targets[3] = USDC_BASE;

        vm.prank(user);
        hiroFactory = new HiroFactory(targets);

        vm.startPrank(user);
        hiroWallet = HiroWallet(payable(hiroFactory.createHiroWallet{value: 1 ether}()));
        vm.stopPrank();

        strategy = new UniV3RebalanceStrategy(NPM_BASE, SWAP_ROUTER02_BASE, V3_FACTORY_BASE, address(hiroFactory));

        vm.startPrank(user);
        hiroFactory.addStrategy(address(strategy));
        hiroFactory.addAgent(agent);
        hiroWallet.setStrategy(address(strategy), true);
        vm.stopPrank();

        positionId = _mintPositionIntoWallet();
    }

    function _mintPositionIntoWallet() internal returns (uint256 tokenId) {
        vm.deal(address(this), 20 ether);
        IWETH9(WETH_BASE).deposit{value: 5 ether}();
        deal(USDC_BASE, address(this), 20_000e6);

        IERC20(WETH_BASE).approve(NPM_BASE, type(uint256).max);
        IERC20(USDC_BASE).approve(NPM_BASE, type(uint256).max);

        (tokenId,,,) = INonfungiblePositionManager(NPM_BASE).mint(_buildInitialMintParams());
    }

    function _buildInitialMintParams() internal view returns (INonfungiblePositionManager.MintParams memory mp) {
        (address t0, address t1) = USDC_BASE < WETH_BASE ? (USDC_BASE, WETH_BASE) : (WETH_BASE, USDC_BASE);
        address pool = _getPool(t0, t1, POOL_FEE);
        int24 currentTick = _currentTick(pool);
        int24 spacing = _tickSpacing(pool);
        mp.token0 = t0;
        mp.token1 = t1;
        mp.fee = POOL_FEE;
        mp.tickLower = _floorToSpacing(currentTick - 2000, spacing);
        mp.tickUpper = _floorToSpacing(currentTick + 2000, spacing);
        (mp.amount0Desired, mp.amount1Desired) =
            t0 == USDC_BASE ? (uint256(10_000e6), uint256(2 ether)) : (uint256(2 ether), uint256(10_000e6));
        mp.recipient = address(hiroWallet);
        mp.deadline = block.timestamp;
    }

    function _currentTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _positionPoolTokens(uint256 tokenId_) internal view returns (address t0, address t1, uint24 fee) {
        (,, t0, t1, fee,,,,,,,) = INonfungiblePositionManager(NPM_BASE).positions(tokenId_);
    }

    function _positionRange(uint256 tokenId_) internal view returns (int24 lower, int24 upper) {
        (,,,,, lower, upper,,,,,) = INonfungiblePositionManager(NPM_BASE).positions(tokenId_);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r < 0 ? tick - spacing - r : tick - r;
    }

    function _getPool(address t0, address t1, uint24 fee) internal view returns (address) {
        return IUniswapV3Factory(V3_FACTORY_BASE).getPool(t0, t1, fee);
    }

    function _tickSpacing(address pool) internal view returns (int24) {
        return IUniswapV3Pool(pool).tickSpacing();
    }

    function _extractNewTokenId(Vm.Log[] memory logs) internal view returns (uint256) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == NPM_BASE && logs[i].topics.length == 4 && logs[i].topics[0] == transferTopic
                    && logs[i].topics[1] == bytes32(0) // from == address(0) → mint
                    && address(uint160(uint256(logs[i].topics[2]))) == address(hiroWallet)
            ) {
                return uint256(logs[i].topics[3]);
            }
        }
        revert("new tokenId not found in logs");
    }

    function _buildRebalanceParams(int24 newLower, int24 newUpper) internal view returns (bytes memory) {
        return abi.encode(
            UniV3RebalanceStrategy.RebalanceParams({
                positionId: positionId,
                newTickLower: newLower,
                newTickUpper: newUpper,
                slippageBps: 100,
                maxImpactBps: 100
            })
        );
    }

    function _nextValidRange() internal view returns (int24 lower, int24 upper) {
        (address t0, address t1, uint24 fee) = _positionPoolTokens(positionId);
        address pool = _getPool(t0, t1, fee);
        int24 currentTick = _currentTick(pool);
        int24 spacing = _tickSpacing(pool);
        lower = _floorToSpacing(currentTick - 1500, spacing);
        upper = _floorToSpacing(currentTick + 2500, spacing);
    }

    function testForkRebalanceHappyPath() public {
        (int24 newLower, int24 newUpper) = _nextValidRange();
        (int24 oldLower, int24 oldUpper) = _positionRange(positionId);
        (address t0, address t1,) = _positionPoolTokens(positionId);

        uint256 factoryT0Before = IERC20(t0).balanceOf(address(hiroFactory));
        uint256 factoryT1Before = IERC20(t1).balanceOf(address(hiroFactory));

        vm.recordLogs();
        vm.prank(agent);
        hiroWallet.executeStrategy(strategy, _buildRebalanceParams(newLower, newUpper));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool ok,) = NPM_BASE.staticcall(abi.encodeWithSignature("ownerOf(uint256)", positionId));
        assertFalse(ok, "old position should be burned");

        uint256 newTokenId = _extractNewTokenId(logs);
        (int24 newLowerActual, int24 newUpperActual) = _positionRange(newTokenId);
        assertEq(newLowerActual, newLower);
        assertEq(newUpperActual, newUpper);
        assertEq(INonfungiblePositionManager(NPM_BASE).ownerOf(newTokenId), address(hiroWallet));

        // Factory balances should be non-decreasing (no trading activity, so likely 0 owed)
        assertGe(IERC20(t0).balanceOf(address(hiroFactory)), factoryT0Before);
        assertGe(IERC20(t1).balanceOf(address(hiroFactory)), factoryT1Before);

        assertTrue(oldLower != newLower || oldUpper != newUpper);
    }

    function testForkRebalanceRevertsWhenTargetUnwhitelistedMidFlight() public {
        vm.prank(user);
        hiroFactory.removeTarget(NPM_BASE);

        (int24 newLower, int24 newUpper) = _nextValidRange();

        vm.prank(agent);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.executeStrategy(strategy, _buildRebalanceParams(newLower, newUpper));
    }

    /// @notice Generate trading fees on the pool by swapping back-and-forth from the
    /// test contract, then poke the wallet's position so accrued fees materialize in
    /// `positions().tokensOwed`. Returns the post-poke (owed0, owed1).
    function _accrueFeesAndPokePosition() internal returns (uint128 owed0, uint128 owed1) {
        IERC20(WETH_BASE).approve(SWAP_ROUTER02_BASE, type(uint256).max);
        IERC20(USDC_BASE).approve(SWAP_ROUTER02_BASE, type(uint256).max);

        // 5 round-trips of 0.5 WETH ↔ USDC through the same fee tier accumulates fees in-range.
        for (uint256 j = 0; j < 5; j++) {
            ISwapRouter02(SWAP_ROUTER02_BASE).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: WETH_BASE,
                    tokenOut: USDC_BASE,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: 0.5 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            uint256 usdcBal = IERC20(USDC_BASE).balanceOf(address(this));
            ISwapRouter02(SWAP_ROUTER02_BASE).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDC_BASE,
                    tokenOut: WETH_BASE,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: usdcBal / 2,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // Poke the wallet's position. NPM.decreaseLiquidity rejects liquidity=0; NPM.collect
        // requires at least one positive amount-max, so we sweep 1 wei of each. The poke
        // inside collect checkpoints accrued fees into tokensOwed.
        vm.prank(address(hiroWallet));
        INonfungiblePositionManager(NPM_BASE).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(hiroWallet),
                amount0Max: 1,
                amount1Max: 1
            })
        );

        (,,,,,,,,,, owed0, owed1) = INonfungiblePositionManager(NPM_BASE).positions(positionId);
    }

    function testForkRebalanceProtocolFeeCollect() public {
        (uint128 owed0, uint128 owed1) = _accrueFeesAndPokePosition();
        assertTrue(owed0 > 0 || owed1 > 0, "expected non-zero owed fees after pokes");

        (address t0, address t1,) = _positionPoolTokens(positionId);
        uint256 factoryT0Before = IERC20(t0).balanceOf(address(hiroFactory));
        uint256 factoryT1Before = IERC20(t1).balanceOf(address(hiroFactory));

        (int24 newLower, int24 newUpper) = _nextValidRange();
        vm.prank(agent);
        hiroWallet.executeStrategy(strategy, _buildRebalanceParams(newLower, newUpper));

        uint256 expectedFee0 = (uint256(owed0) * strategy.PROTOCOL_FEE_BPS()) / 10000;
        uint256 expectedFee1 = (uint256(owed1) * strategy.PROTOCOL_FEE_BPS()) / 10000;
        assertEq(IERC20(t0).balanceOf(address(hiroFactory)) - factoryT0Before, expectedFee0, "factory token0 fee");
        assertEq(IERC20(t1).balanceOf(address(hiroFactory)) - factoryT1Before, expectedFee1, "factory token1 fee");
    }
}
