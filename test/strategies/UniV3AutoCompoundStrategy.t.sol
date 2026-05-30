// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {HiroFactory} from "../../src/HiroFactory.sol";
import {HiroWallet} from "../../src/HiroWallet.sol";
import {IHiroWallet} from "../../src/interfaces/IHiroWallet.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {UniV3AutoCompoundStrategy} from "../../src/strategies/UniV3AutoCompoundStrategy.sol";
import {V3MathLib} from "../../src/libraries/V3MathLib.sol";
import {MockNonfungiblePositionManager} from "../mocks/MockNonfungiblePositionManager.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ═══════════════════════════════════════════════════════════════════════════
// UNIT TESTS — mock-backed, no fork required
// ═══════════════════════════════════════════════════════════════════════════
contract UniV3AutoCompoundStrategyUnitTest is Test {
    MockNonfungiblePositionManager npm;
    MockUniswapV3Pool pool;
    MockUniswapV3Factory v3Factory;
    UniV3AutoCompoundStrategy strategy;

    address wallet = address(0xBEEF);
    address hiroFactory = address(0xDEAD);
    address token0 = address(0x1111);
    address token1 = address(0x2222);
    uint24 poolFee = 500;
    uint256 positionId = 1;
    uint16 constant MIN_COMPOUND_BPS = 100; // 1%
    uint160 constant SQRT_PRICE_AT_TICK_0 = 0x1000000000000000000000000; // 2^96
    uint256 constant Q128 = V3MathLib.Q128;

    function setUp() public {
        npm = new MockNonfungiblePositionManager();
        pool = new MockUniswapV3Pool(SQRT_PRICE_AT_TICK_0, 0, 10);
        v3Factory = new MockUniswapV3Factory();
        v3Factory.setPool(token0, token1, poolFee, address(pool));

        strategy = new UniV3AutoCompoundStrategy(
            address(npm), address(0x3333), address(v3Factory), hiroFactory, MIN_COMPOUND_BPS
        );

        npm.setOwner(positionId, wallet);
        // Default: balanced position with sizable owed fees (floor passes, swap happens).
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 2e18, 0);
    }

    function _params(uint16 slip, uint16 imp) internal view returns (bytes memory) {
        return abi.encode(
            UniV3AutoCompoundStrategy.CompoundParams({positionId: positionId, slippageBps: slip, maxImpactBps: imp})
        );
    }

    // ── validation ────────────────────────────────────────────────────────────

    function testRevertSlippageTooHigh() public {
        vm.expectRevert(UniV3AutoCompoundStrategy.SlippageTooHigh.selector);
        strategy.plan(wallet, _params(101, 50));
    }

    function testRevertImpactTooHigh() public {
        vm.expectRevert(UniV3AutoCompoundStrategy.ImpactTooHigh.selector);
        strategy.plan(wallet, _params(50, 301));
    }

    function testRevertNotPositionOwner() public {
        npm.setOwner(positionId, address(0xC0FFEE));
        vm.expectRevert(UniV3AutoCompoundStrategy.NotPositionOwner.selector);
        strategy.plan(wallet, _params(50, 50));
    }

    function testRevertPoolNotFound() public {
        npm.setPosition(positionId, address(0x9999), address(0xAAAA), 500, -1000, 1000, 1e18, 2e18, 0);
        vm.expectRevert(UniV3AutoCompoundStrategy.PoolNotFound.selector);
        strategy.plan(wallet, _params(50, 50));
    }

    function testRevertConstructorBadMinBps() public {
        vm.expectRevert(UniV3AutoCompoundStrategy.InvalidMinCompoundBps.selector);
        new UniV3AutoCompoundStrategy(address(npm), address(0x3333), address(v3Factory), hiroFactory, 10001);
    }

    // ── floor ───────────────────────────────────────────────────────────────

    function testRevertBelowMinCompound() public {
        // Tiny fees on a large position → fees far below 1% of principal.
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 1, 1);
        vm.expectRevert(UniV3AutoCompoundStrategy.BelowMinCompound.selector);
        strategy.plan(wallet, _params(50, 50));
    }

    function testRevertBelowMinCompoundWhenNoFees() public {
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 0, 0);
        vm.expectRevert(UniV3AutoCompoundStrategy.BelowMinCompound.selector);
        strategy.plan(wallet, _params(50, 50));
    }

    // ── plan shape ────────────────────────────────────────────────────────────

    function testPlanShapeWithSwap() public view {
        // Default position is one-sided (owed0=2e18, owed1=0) → a swap is required.
        IHiroWallet.Call[] memory calls = strategy.plan(wallet, _params(100, 100));
        assertEq(calls.length, 7, "protocol-collect + collect + approve + swap + approve0 + approve1 + increase");

        // First call routes the protocol fee to the factory; last call increases liquidity.
        assertEq(calls[0].target, address(npm));
        assertEq(_selector(calls[0].data), INonfungiblePositionManager.collect.selector);
        assertEq(_decodeCollect(calls[0].data).recipient, hiroFactory);
        assertEq(_selector(calls[calls.length - 1].data), INonfungiblePositionManager.increaseLiquidity.selector);

        // Same NFT, same range: no decrease / burn / mint anywhere in the bundle.
        bool hasSwap;
        for (uint256 i = 0; i < calls.length; i++) {
            bytes4 sel = _selector(calls[i].data);
            assertTrue(sel != INonfungiblePositionManager.decreaseLiquidity.selector, "no decrease");
            assertTrue(sel != INonfungiblePositionManager.burn.selector, "no burn");
            assertTrue(sel != INonfungiblePositionManager.mint.selector, "no mint");
            if (sel == ISwapRouter02.exactInputSingle.selector) hasSwap = true;
        }
        assertTrue(hasSwap, "expected a swap for the one-sided position");
    }

    function testPlanSkipsSwapWhenBelowDust() public {
        // Small, balanced position: the optimal swap is below MIN_SWAP_DUST → no swap calls.
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e6, 1000, 1000);
        IHiroWallet.Call[] memory calls = strategy.plan(wallet, _params(100, 100));
        assertEq(calls.length, 5, "protocol-collect + collect + approve0 + approve1 + increase (no swap)");
        for (uint256 i = 0; i < calls.length; i++) {
            assertTrue(_selector(calls[i].data) != ISwapRouter02.exactInputSingle.selector, "no swap expected");
        }
    }

    // ── fee-growth wiring: protocol fee == 10% of computed uncollected ──────────

    function testProtocolFeeMatchesUncollected() public {
        // Accrued (un-poked) fees on both sides: tokensOwed + fee-growth delta.
        pool.setFeeGrowthGlobal(Q128, Q128); // inside = Q128 (outsides default 0) → delta = Q128
        npm.setPosition(positionId, token0, token1, poolFee, -1000, 1000, 1e18, 5e17, 5e17);

        // Expected uncollected via the same pure math the strategy uses.
        V3MathLib.FeeGrowthInputs memory f;
        f.tickCurrent = 0;
        f.tickLower = -1000;
        f.tickUpper = 1000;
        f.feeGrowthGlobal0X128 = Q128;
        f.feeGrowthGlobal1X128 = Q128;
        f.liquidity = 1e18;
        f.tokensOwed0 = 5e17;
        f.tokensOwed1 = 5e17;
        (uint256 u0, uint256 u1) = V3MathLib.getUncollectedFees(f);
        assertEq(u0, 5e17 + 1e18); // sanity: 5e17 owed + 1e18 accrued
        assertEq(u1, 5e17 + 1e18);

        IHiroWallet.Call[] memory calls = strategy.plan(wallet, _params(100, 100));
        INonfungiblePositionManager.CollectParams memory cp = _decodeCollect(calls[0].data);
        assertEq(cp.recipient, hiroFactory);
        assertEq(uint256(cp.amount0Max), (u0 * strategy.PROTOCOL_FEE_BPS()) / 10000, "protocol fee0 = 10% uncollected");
        assertEq(uint256(cp.amount1Max), (u1 * strategy.PROTOCOL_FEE_BPS()) / 10000, "protocol fee1 = 10% uncollected");
    }

    // ── V3MathLib.getUncollectedFees: direct math ───────────────────────────────

    function testGetUncollectedFeesNormal() public pure {
        V3MathLib.FeeGrowthInputs memory f;
        f.tickCurrent = 0;
        f.tickLower = -1000;
        f.tickUpper = 1000;
        f.feeGrowthGlobal0X128 = Q128; // inside0 = Q128
        f.feeGrowthGlobal1X128 = 2 * Q128; // inside1 = 2*Q128
        f.liquidity = 1e18;
        f.tokensOwed0 = 5e17;
        f.tokensOwed1 = 0;
        (uint256 u0, uint256 u1) = V3MathLib.getUncollectedFees(f);
        assertEq(u0, 5e17 + 1e18); // owed + mulDiv(Q128, 1e18, Q128)
        assertEq(u1, 2e18); // 0 + mulDiv(2*Q128, 1e18, Q128)
    }

    function testGetUncollectedFeesWrap() public pure {
        // feeGrowthInside (0) < feeGrowthInsideLast (2^256 − Q128): the delta must wrap to Q128.
        V3MathLib.FeeGrowthInputs memory f;
        f.tickCurrent = 0;
        f.tickLower = -1000;
        f.tickUpper = 1000;
        f.feeGrowthGlobal0X128 = 0; // inside0 = 0
        f.feeGrowthInside0LastX128 = type(uint256).max - Q128 + 1; // = 2^256 − Q128
        f.liquidity = 1e18;
        f.tokensOwed0 = 1e17;
        (uint256 u0,) = V3MathLib.getUncollectedFees(f);
        assertEq(u0, 1e17 + 1e18); // delta wraps to Q128 → mulDiv(Q128, 1e18, Q128) = 1e18
    }

    function testGetUncollectedFeesOutOfRangeAbove() public pure {
        // Spot above the range: feeGrowthAbove uses global − outsideUpper.
        V3MathLib.FeeGrowthInputs memory f;
        f.tickCurrent = 2000; // above tickUpper
        f.tickLower = -1000;
        f.tickUpper = 1000;
        f.feeGrowthGlobal0X128 = 3 * Q128;
        f.feeGrowthOutsideLower0X128 = Q128;
        f.feeGrowthOutsideUpper0X128 = Q128;
        f.liquidity = 1e18;
        // spot >= lower → below0 = outsideLower = Q128
        // spot >= upper → above0 = global − outsideUpper = 3Q128 − Q128 = 2Q128
        // inside0 = 3Q128 − Q128 − 2Q128 = 0
        (uint256 u0,) = V3MathLib.getUncollectedFees(f);
        assertEq(u0, 0);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        assembly {
            sel := mload(add(data, 0x20))
        }
    }

    function _decodeCollect(bytes memory data)
        internal
        pure
        returns (INonfungiblePositionManager.CollectParams memory cp)
    {
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = data[i + 4];
        }
        cp = abi.decode(args, (INonfungiblePositionManager.CollectParams));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// FORK TESTS — runs against Base mainnet via BASE_RPC_URL (or public default)
// ═══════════════════════════════════════════════════════════════════════════
contract UniV3AutoCompoundStrategyForkTest is Test {
    address constant NPM_BASE = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER02_BASE = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant V3_FACTORY_BASE = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint24 constant POOL_FEE = 500; // 0.05%

    HiroFactory hiroFactory;
    HiroWallet hiroWallet;
    UniV3AutoCompoundStrategy strategy; // minCompoundBps = 0 → flow exercised with modest fees
    UniV3AutoCompoundStrategy strictStrategy; // minCompoundBps = 100% → floor always trips

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

        strategy = new UniV3AutoCompoundStrategy(NPM_BASE, SWAP_ROUTER02_BASE, V3_FACTORY_BASE, address(hiroFactory), 0);
        strictStrategy =
            new UniV3AutoCompoundStrategy(NPM_BASE, SWAP_ROUTER02_BASE, V3_FACTORY_BASE, address(hiroFactory), 10000);

        vm.startPrank(user);
        hiroFactory.addStrategy(address(strategy));
        hiroFactory.addStrategy(address(strictStrategy));
        hiroFactory.addAgent(agent);
        vm.stopPrank();

        positionId = _mintPositionIntoWallet();
    }

    function _params(uint256 id) internal pure returns (bytes memory) {
        return
            abi.encode(UniV3AutoCompoundStrategy.CompoundParams({positionId: id, slippageBps: 100, maxImpactBps: 100}));
    }

    function testForkAutoCompoundHappyPath() public {
        _accrueFees();

        uint128 liqBefore = _liquidity(positionId);
        (int24 lowerBefore, int24 upperBefore) = _positionRange(positionId);
        (address t0, address t1,) = _positionPoolTokens(positionId);
        uint256 facT0Before = IERC20(t0).balanceOf(address(hiroFactory));
        uint256 facT1Before = IERC20(t1).balanceOf(address(hiroFactory));

        // Learn the total claimable fees by simulating a full collect, then revert.
        (uint256 totalFee0, uint256 totalFee1) = _simulateFullCollect();
        assertTrue(totalFee0 > 0 || totalFee1 > 0, "expected non-zero fees accrued");

        vm.prank(agent);
        hiroWallet.executeStrategy(strategy, _params(positionId));

        // Same NFT, unchanged range.
        assertEq(INonfungiblePositionManager(NPM_BASE).ownerOf(positionId), address(hiroWallet), "same NFT");
        (int24 lowerAfter, int24 upperAfter) = _positionRange(positionId);
        assertEq(lowerAfter, lowerBefore);
        assertEq(upperAfter, upperBefore);

        // Liquidity grew.
        assertGt(_liquidity(positionId), liqBefore, "liquidity compounded");

        // Factory received ~10% of the fees.
        uint256 expFee0 = (totalFee0 * strategy.PROTOCOL_FEE_BPS()) / 10000;
        uint256 expFee1 = (totalFee1 * strategy.PROTOCOL_FEE_BPS()) / 10000;
        assertApproxEqAbs(IERC20(t0).balanceOf(address(hiroFactory)) - facT0Before, expFee0, 2, "factory token0 fee");
        assertApproxEqAbs(IERC20(t1).balanceOf(address(hiroFactory)) - facT1Before, expFee1, 2, "factory token1 fee");
    }

    function testForkAutoCompoundBelowFloorReverts() public {
        // Real (modest) fees, but the strict strategy demands 100% of principal → trips the floor.
        _accrueFees();
        vm.prank(agent);
        vm.expectRevert(UniV3AutoCompoundStrategy.BelowMinCompound.selector);
        hiroWallet.executeStrategy(strictStrategy, _params(positionId));
    }

    function testForkAutoCompoundRevertsWhenTargetUnwhitelisted() public {
        _accrueFees();
        vm.prank(user);
        hiroFactory.removeTarget(NPM_BASE);

        vm.prank(agent);
        vm.expectRevert(HiroFactory.TargetNotWhitelisted.selector);
        hiroWallet.executeStrategy(strategy, _params(positionId));
    }

    // ── helpers ─────────────────────────────────────────────────────────────

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

    /// @notice Generate trading fees on the pool by round-tripping WETH↔USDC. Unlike the
    /// rebalance fork test, the position is intentionally NOT poked — auto-compound must
    /// recover the accrued fees via fee-growth math.
    function _accrueFees() internal {
        vm.deal(address(this), 200 ether);
        IWETH9(WETH_BASE).deposit{value: 100 ether}();
        deal(USDC_BASE, address(this), 500_000e6);
        IERC20(WETH_BASE).approve(SWAP_ROUTER02_BASE, type(uint256).max);
        IERC20(USDC_BASE).approve(SWAP_ROUTER02_BASE, type(uint256).max);

        for (uint256 j = 0; j < 8; j++) {
            uint256 out = ISwapRouter02(SWAP_ROUTER02_BASE).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: WETH_BASE,
                    tokenOut: USDC_BASE,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: 5 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            // Swap the proceeds back so price oscillates around the start and stays in range.
            ISwapRouter02(SWAP_ROUTER02_BASE).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDC_BASE,
                    tokenOut: WETH_BASE,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: out,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    /// @dev Snapshots state, collects all fees to the wallet to read the true claimable
    /// amounts, then reverts so the strategy sees the un-collected position.
    function _simulateFullCollect() internal returns (uint256 amount0, uint256 amount1) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(hiroWallet));
        (amount0, amount1) = INonfungiblePositionManager(NPM_BASE).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(hiroWallet),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        vm.revertToState(snap);
    }

    function _liquidity(uint256 tokenId_) internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = INonfungiblePositionManager(NPM_BASE).positions(tokenId_);
    }

    function _positionPoolTokens(uint256 tokenId_) internal view returns (address t0, address t1, uint24 fee) {
        (,, t0, t1, fee,,,,,,,) = INonfungiblePositionManager(NPM_BASE).positions(tokenId_);
    }

    function _positionRange(uint256 tokenId_) internal view returns (int24 lower, int24 upper) {
        (,,,,, lower, upper,,,,,) = INonfungiblePositionManager(NPM_BASE).positions(tokenId_);
    }

    function _currentTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
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
}
