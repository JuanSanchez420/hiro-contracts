// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IHiroWallet.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ISwapRouter02.sol";
import "../libraries/LiquidityAmounts.sol";
import "../libraries/TickMath.sol";
import "../libraries/V3MathLib.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title UniV3RebalanceStrategy
/// @notice Rebalances a Uniswap V3 LP position into a new range. Returns the full
/// decrease → collect → burn → (swap) → mint sequence as a single Call[].
contract UniV3RebalanceStrategy is IStrategy {
    error InvalidAddress();
    error SlippageTooHigh();
    error ImpactTooHigh();
    error RangeNotAroundSpot();
    error RangeTooNarrow();
    error RangeTooWide();
    error TickOutOfRange();
    error TickNotAligned();
    error InvalidTickSpacing();
    error NotPositionOwner();
    error PoolNotFound();

    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_IMPACT_BPS = 300;
    uint16 public constant PROTOCOL_FEE_BPS = 1000;
    int24 public constant MIN_WIDTH_TICKS = 200;
    int24 public constant MAX_WIDTH_TICKS = 60_000;
    uint256 public constant MIN_SWAP_DUST = 1e6;

    address public immutable npm;
    address public immutable swapRouter;
    address public immutable v3Factory;
    address public immutable hiroFactory;

    struct RebalanceParams {
        uint256 positionId;
        int24 newTickLower;
        int24 newTickUpper;
        uint16 slippageBps;
        uint16 maxImpactBps;
    }

    constructor(address _npm, address _swapRouter, address _v3Factory, address _hiroFactory) {
        if (_npm == address(0) || _swapRouter == address(0) || _v3Factory == address(0) || _hiroFactory == address(0)) {
            revert InvalidAddress();
        }
        npm = _npm;
        swapRouter = _swapRouter;
        v3Factory = _v3Factory;
        hiroFactory = _hiroFactory;
    }

    function plan(address wallet, bytes calldata params)
        external
        view
        override
        returns (IHiroWallet.Call[] memory calls)
    {
        RebalanceParams memory p = abi.decode(params, (RebalanceParams));
        if (p.slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        if (p.maxImpactBps > MAX_IMPACT_BPS) revert ImpactTooHigh();

        PlanState memory s = _readState(wallet, p.positionId);
        _validateRange(p, s.currentTick, s.tickSpacing);

        return _buildCalls(wallet, p, s);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    struct PlanState {
        address token0;
        address token1;
        uint24 poolFee;
        int24 oldTickLower;
        int24 oldTickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 tickSpacing;
    }

    function _readState(address wallet, uint256 positionId) internal view returns (PlanState memory s) {
        (,, s.token0, s.token1, s.poolFee, s.oldTickLower, s.oldTickUpper, s.liquidity,,, s.tokensOwed0, s.tokensOwed1)
        = INonfungiblePositionManager(npm).positions(positionId);

        if (INonfungiblePositionManager(npm).ownerOf(positionId) != wallet) revert NotPositionOwner();

        address pool = IUniswapV3Factory(v3Factory).getPool(s.token0, s.token1, s.poolFee);
        if (pool == address(0)) revert PoolNotFound();

        (s.sqrtPriceX96, s.currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        s.tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        if (s.tickSpacing <= 0) revert InvalidTickSpacing();
    }

    function _validateRange(RebalanceParams memory p, int24 currentTick, int24 tickSpacing) internal pure {
        if (p.newTickLower < TickMath.MIN_TICK || p.newTickUpper > TickMath.MAX_TICK) revert TickOutOfRange();
        if (!(p.newTickLower < currentTick && currentTick < p.newTickUpper)) revert RangeNotAroundSpot();
        int24 width = p.newTickUpper - p.newTickLower;
        if (width < MIN_WIDTH_TICKS) revert RangeTooNarrow();
        if (width > MAX_WIDTH_TICKS) revert RangeTooWide();
        if (p.newTickLower % tickSpacing != 0 || p.newTickUpper % tickSpacing != 0) revert TickNotAligned();
    }

    struct PlanAmounts {
        uint256 decAmt0Min;
        uint256 decAmt1Min;
        uint128 protocolFee0;
        uint128 protocolFee1;
        uint256 walletAmt0;
        uint256 walletAmt1;
        bool zeroForOne;
        uint256 swapAmountIn;
        uint256 swapAmountOutMinimum;
        uint256 mintAmt0;
        uint256 mintAmt1;
        uint256 mintAmt0Min;
        uint256 mintAmt1Min;
    }

    function _planAmounts(RebalanceParams memory p, PlanState memory s) internal pure returns (PlanAmounts memory a) {
        (uint256 amt0Released, uint256 amt1Released) =
            V3MathLib.getAmountsForLiquidity(s.sqrtPriceX96, s.oldTickLower, s.oldTickUpper, s.liquidity);
        a.decAmt0Min = (amt0Released * (10000 - p.slippageBps)) / 10000;
        a.decAmt1Min = (amt1Released * (10000 - p.slippageBps)) / 10000;

        a.protocolFee0 = uint128((uint256(s.tokensOwed0) * PROTOCOL_FEE_BPS) / 10000);
        a.protocolFee1 = uint128((uint256(s.tokensOwed1) * PROTOCOL_FEE_BPS) / 10000);

        a.walletAmt0 = amt0Released + (s.tokensOwed0 - a.protocolFee0);
        a.walletAmt1 = amt1Released + (s.tokensOwed1 - a.protocolFee1);

        // Cache new-range sqrt ratios — used by computeOptimalSwap, getLiquidityForAmounts, getAmountsForLiquidity.
        uint160 sqrtLowerX96 = TickMath.getSqrtRatioAtTick(p.newTickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtRatioAtTick(p.newTickUpper);

        (a.zeroForOne, a.swapAmountIn) =
            V3MathLib.computeOptimalSwap(a.walletAmt0, a.walletAmt1, s.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96);
        bool needsSwap = a.swapAmountIn >= MIN_SWAP_DUST;

        if (needsSwap) {
            uint256 spotOut = a.zeroForOne
                ? V3MathLib.valueOfToken0InToken1(a.swapAmountIn, s.sqrtPriceX96)
                : V3MathLib.valueOfToken1InToken0(a.swapAmountIn, s.sqrtPriceX96);
            a.swapAmountOutMinimum = (spotOut * (10000 - uint256(p.slippageBps) - uint256(p.maxImpactBps))) / 10000;
            if (a.zeroForOne) {
                a.mintAmt0 = a.walletAmt0 - a.swapAmountIn;
                a.mintAmt1 = a.walletAmt1 + a.swapAmountOutMinimum;
            } else {
                a.mintAmt0 = a.walletAmt0 + a.swapAmountOutMinimum;
                a.mintAmt1 = a.walletAmt1 - a.swapAmountIn;
            }
        } else {
            a.mintAmt0 = a.walletAmt0;
            a.mintAmt1 = a.walletAmt1;
        }

        uint128 liq =
            LiquidityAmounts.getLiquidityForAmounts(s.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, a.mintAmt0, a.mintAmt1);
        (uint256 expAmt0, uint256 expAmt1) =
            LiquidityAmounts.getAmountsForLiquidity(s.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liq);

        // Post-swap, the pool's sqrtP has shifted by up to maxImpactBps. Mint sees the new
        // sqrtP and may require slightly different amounts than `expAmt0/expAmt1` computed
        // at the pre-swap sqrtP. Expand the slippage floor by maxImpactBps when a swap ran.
        uint256 mintSlippageBps = needsSwap ? uint256(p.slippageBps) + uint256(p.maxImpactBps) : uint256(p.slippageBps);
        a.mintAmt0Min = (expAmt0 * (10000 - mintSlippageBps)) / 10000;
        a.mintAmt1Min = (expAmt1 * (10000 - mintSlippageBps)) / 10000;
    }

    function _buildCalls(address wallet, RebalanceParams memory p, PlanState memory s)
        internal
        view
        returns (IHiroWallet.Call[] memory calls)
    {
        PlanAmounts memory a = _planAmounts(p, s);

        uint256 callCount = 6; // decrease, collect-wallet, burn, approve0, approve1, mint
        bool hasProtocolFee = a.protocolFee0 > 0 || a.protocolFee1 > 0;
        bool needsSwap = a.swapAmountIn >= MIN_SWAP_DUST;
        if (hasProtocolFee) callCount++;
        if (needsSwap) callCount += 2;

        calls = new IHiroWallet.Call[](callCount);
        uint256 i = 0;

        calls[i++] = IHiroWallet.Call({
            target: npm,
            value: 0,
            data: abi.encodeCall(
                INonfungiblePositionManager.decreaseLiquidity,
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: p.positionId,
                    liquidity: s.liquidity,
                    amount0Min: a.decAmt0Min,
                    amount1Min: a.decAmt1Min,
                    deadline: block.timestamp
                })
            )
        });

        if (hasProtocolFee) {
            calls[i++] = IHiroWallet.Call({
                target: npm,
                value: 0,
                data: abi.encodeCall(
                    INonfungiblePositionManager.collect,
                    INonfungiblePositionManager.CollectParams({
                        tokenId: p.positionId,
                        recipient: hiroFactory,
                        amount0Max: a.protocolFee0,
                        amount1Max: a.protocolFee1
                    })
                )
            });
        }

        calls[i++] = IHiroWallet.Call({
            target: npm,
            value: 0,
            data: abi.encodeCall(
                INonfungiblePositionManager.collect,
                INonfungiblePositionManager.CollectParams({
                    tokenId: p.positionId,
                    recipient: wallet,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            )
        });

        calls[i++] = IHiroWallet.Call({
            target: npm,
            value: 0,
            data: abi.encodeCall(INonfungiblePositionManager.burn, (p.positionId))
        });

        if (needsSwap) {
            address tokenIn = a.zeroForOne ? s.token0 : s.token1;
            address tokenOut = a.zeroForOne ? s.token1 : s.token0;
            calls[i++] = IHiroWallet.Call({
                target: tokenIn,
                value: 0,
                data: abi.encodeCall(IERC20.approve, (swapRouter, a.swapAmountIn))
            });
            calls[i++] = IHiroWallet.Call({
                target: swapRouter,
                value: 0,
                data: abi.encodeCall(
                    ISwapRouter02.exactInputSingle,
                    ISwapRouter02.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: s.poolFee,
                        recipient: wallet,
                        amountIn: a.swapAmountIn,
                        amountOutMinimum: a.swapAmountOutMinimum,
                        sqrtPriceLimitX96: 0
                    })
                )
            });
        }

        calls[i++] =
            IHiroWallet.Call({target: s.token0, value: 0, data: abi.encodeCall(IERC20.approve, (npm, a.mintAmt0))});
        calls[i++] =
            IHiroWallet.Call({target: s.token1, value: 0, data: abi.encodeCall(IERC20.approve, (npm, a.mintAmt1))});

        calls[i++] = IHiroWallet.Call({
            target: npm,
            value: 0,
            data: abi.encodeCall(
                INonfungiblePositionManager.mint,
                INonfungiblePositionManager.MintParams({
                    token0: s.token0,
                    token1: s.token1,
                    fee: s.poolFee,
                    tickLower: p.newTickLower,
                    tickUpper: p.newTickUpper,
                    amount0Desired: a.mintAmt0,
                    amount1Desired: a.mintAmt1,
                    amount0Min: a.mintAmt0Min,
                    amount1Min: a.mintAmt1Min,
                    recipient: wallet,
                    deadline: block.timestamp
                })
            )
        });
    }
}
