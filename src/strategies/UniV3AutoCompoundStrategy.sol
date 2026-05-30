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

/// @title UniV3AutoCompoundStrategy
/// @notice Compounds a Uniswap V3 LP position in place: collect fees → swap to the
/// position's current ratio → re-deposit via `increaseLiquidity`. Same NFT, same range
/// (no decrease/burn/mint). Returns the full sequence as a single Call[].
contract UniV3AutoCompoundStrategy is IStrategy {
    error InvalidAddress();
    error InvalidMinCompoundBps();
    error SlippageTooHigh();
    error ImpactTooHigh();
    error NotPositionOwner();
    error PoolNotFound();
    error BelowMinCompound();

    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_IMPACT_BPS = 300;
    uint16 public constant PROTOCOL_FEE_BPS = 1000;
    uint256 public constant MIN_SWAP_DUST = 1e6;

    address public immutable npm;
    address public immutable swapRouter;
    address public immutable v3Factory;
    address public immutable hiroFactory;

    /// @notice Relative dust floor: the wallet-bound fees being compounded must be at least
    /// this many bps of the position's current principal (both valued in token1 at spot).
    /// Oracle-free and pool-agnostic — it's a ratio of two amounts priced at the same sqrtP,
    /// so it needs no external price feed. This is a grief/dust guard, not a value guarantee;
    /// per-call slippage + impact caps protect value. Set per deployment (production uses 100
    /// = 1%); a volatile pool that earns fees fast can run a higher floor, a stable pair a
    /// lower one. `0` disables the floor.
    uint16 public immutable minCompoundBps;

    struct CompoundParams {
        uint256 positionId;
        uint16 slippageBps;
        uint16 maxImpactBps;
    }

    constructor(address _npm, address _swapRouter, address _v3Factory, address _hiroFactory, uint16 _minCompoundBps) {
        if (_npm == address(0) || _swapRouter == address(0) || _v3Factory == address(0) || _hiroFactory == address(0)) {
            revert InvalidAddress();
        }
        if (_minCompoundBps > 10000) revert InvalidMinCompoundBps();
        npm = _npm;
        swapRouter = _swapRouter;
        v3Factory = _v3Factory;
        hiroFactory = _hiroFactory;
        minCompoundBps = _minCompoundBps;
    }

    function plan(address wallet, bytes calldata params)
        external
        view
        override
        returns (IHiroWallet.Call[] memory calls)
    {
        CompoundParams memory p = abi.decode(params, (CompoundParams));
        if (p.slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        if (p.maxImpactBps > MAX_IMPACT_BPS) revert ImpactTooHigh();

        PlanState memory s = _readState(wallet, p.positionId);
        return _buildCalls(wallet, p, s);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    struct PlanState {
        address token0;
        address token1;
        uint24 poolFee;
        int24 tickLower; // existing range — unchanged by compound
        int24 tickUpper;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint256 uncollected0; // current claimable fees (incl. accrued-since-poke)
        uint256 uncollected1;
    }

    function _readState(address wallet, uint256 positionId) internal view returns (PlanState memory s) {
        // Core position fields only (range + tokens + liquidity). Kept to 6 destructured
        // values — keeping the fee-growth fields here too would blow the stack, so they're
        // read separately in `_uncollectedFees`.
        (,, s.token0, s.token1, s.poolFee, s.tickLower, s.tickUpper, s.liquidity,,,,) =
            INonfungiblePositionManager(npm).positions(positionId);

        if (INonfungiblePositionManager(npm).ownerOf(positionId) != wallet) revert NotPositionOwner();

        address pool = IUniswapV3Factory(v3Factory).getPool(s.token0, s.token1, s.poolFee);
        if (pool == address(0)) revert PoolNotFound();

        (s.sqrtPriceX96, s.currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        s.sqrtLowerX96 = TickMath.getSqrtRatioAtTick(s.tickLower);
        s.sqrtUpperX96 = TickMath.getSqrtRatioAtTick(s.tickUpper);

        (s.uncollected0, s.uncollected1) = _uncollectedFees(pool, positionId, s);
    }

    /// @dev Reads the position's fee-growth checkpoint and the pool-side fee-growth inputs, then
    /// delegates to the pure math. Auto-compound never `decreaseLiquidity`-pokes, so
    /// `tokensOwed*` alone undercounts; this recovers the fees accrued since the last poke.
    /// Fields are written straight into the memory struct to keep the stack shallow.
    function _uncollectedFees(address pool, uint256 positionId, PlanState memory s)
        internal
        view
        returns (uint256 uncollected0, uint256 uncollected1)
    {
        V3MathLib.FeeGrowthInputs memory f;
        f.tickCurrent = s.currentTick;
        f.tickLower = s.tickLower;
        f.tickUpper = s.tickUpper;
        f.liquidity = s.liquidity;
        (,,,,,,,, f.feeGrowthInside0LastX128, f.feeGrowthInside1LastX128, f.tokensOwed0, f.tokensOwed1) =
            INonfungiblePositionManager(npm).positions(positionId);
        f.feeGrowthGlobal0X128 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        f.feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        (,, f.feeGrowthOutsideLower0X128, f.feeGrowthOutsideLower1X128,,,,) = IUniswapV3Pool(pool).ticks(s.tickLower);
        (,, f.feeGrowthOutsideUpper0X128, f.feeGrowthOutsideUpper1X128,,,,) = IUniswapV3Pool(pool).ticks(s.tickUpper);
        return V3MathLib.getUncollectedFees(f);
    }

    struct PlanAmounts {
        uint128 protocolFee0;
        uint128 protocolFee1;
        uint256 walletAmt0;
        uint256 walletAmt1;
        bool zeroForOne;
        uint256 swapAmountIn;
        uint256 swapAmountOutMinimum;
        uint256 incAmt0;
        uint256 incAmt1;
        uint256 incAmt0Min;
        uint256 incAmt1Min;
    }

    function _planAmounts(CompoundParams memory p, PlanState memory s) internal view returns (PlanAmounts memory a) {
        // 10% of fees to the factory; the rest is the wallet-bound amount we compound.
        a.protocolFee0 = uint128((s.uncollected0 * PROTOCOL_FEE_BPS) / 10000);
        a.protocolFee1 = uint128((s.uncollected1 * PROTOCOL_FEE_BPS) / 10000);
        a.walletAmt0 = s.uncollected0 - a.protocolFee0;
        a.walletAmt1 = s.uncollected1 - a.protocolFee1;

        _enforceMinCompound(s, a.walletAmt0, a.walletAmt1);

        (a.zeroForOne, a.swapAmountIn) =
            V3MathLib.computeOptimalSwap(a.walletAmt0, a.walletAmt1, s.sqrtPriceX96, s.sqrtLowerX96, s.sqrtUpperX96);
        bool needsSwap = a.swapAmountIn >= MIN_SWAP_DUST;

        if (needsSwap) {
            uint256 spotOut = a.zeroForOne
                ? V3MathLib.valueOfToken0InToken1(a.swapAmountIn, s.sqrtPriceX96)
                : V3MathLib.valueOfToken1InToken0(a.swapAmountIn, s.sqrtPriceX96);
            a.swapAmountOutMinimum = (spotOut * (10000 - uint256(p.slippageBps) - uint256(p.maxImpactBps))) / 10000;
            if (a.zeroForOne) {
                a.incAmt0 = a.walletAmt0 - a.swapAmountIn;
                a.incAmt1 = a.walletAmt1 + a.swapAmountOutMinimum;
            } else {
                a.incAmt0 = a.walletAmt0 + a.swapAmountOutMinimum;
                a.incAmt1 = a.walletAmt1 - a.swapAmountIn;
            }
        } else {
            a.incAmt0 = a.walletAmt0;
            a.incAmt1 = a.walletAmt1;
        }

        // `incAmt0/incAmt1` are estimates of the post-collect, post-swap wallet balances — the
        // same property the rebalance strategy has with `mintAmt*`. `plan()` runs in the same tx
        // as `_execute`, so the uncollected estimate and the `type(uint128).max` wallet-collect
        // read the same fee-growth snapshot and agree to the wei except integer-division
        // rounding; the protocol-fee floor (10% rounded down) leaves the wallet's real balance
        // >= the estimate, so `increaseLiquidity` never over-pulls. `incAmt*Min` enforces
        // slippage on-chain; any dust left over stays in the wallet.
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            s.sqrtPriceX96, s.sqrtLowerX96, s.sqrtUpperX96, a.incAmt0, a.incAmt1
        );
        (uint256 expAmt0, uint256 expAmt1) =
            LiquidityAmounts.getAmountsForLiquidity(s.sqrtPriceX96, s.sqrtLowerX96, s.sqrtUpperX96, liq);

        // Post-swap sqrtP shifts by up to maxImpactBps; widen the deposit floor accordingly.
        uint256 incSlippageBps = needsSwap ? uint256(p.slippageBps) + uint256(p.maxImpactBps) : uint256(p.slippageBps);
        a.incAmt0Min = (expAmt0 * (10000 - incSlippageBps)) / 10000;
        a.incAmt1Min = (expAmt1 * (10000 - incSlippageBps)) / 10000;
    }

    /// @dev Relative floor: the compounded fees must be >= MIN_COMPOUND_BPS of the position's
    /// current principal, both valued in token1 at the pool spot price. No oracle.
    function _enforceMinCompound(PlanState memory s, uint256 walletAmt0, uint256 walletAmt1) internal view {
        (uint256 principal0, uint256 principal1) =
            LiquidityAmounts.getAmountsForLiquidity(s.sqrtPriceX96, s.sqrtLowerX96, s.sqrtUpperX96, s.liquidity);
        uint256 principalValue = principal1 + V3MathLib.valueOfToken0InToken1(principal0, s.sqrtPriceX96);
        uint256 feeValue = walletAmt1 + V3MathLib.valueOfToken0InToken1(walletAmt0, s.sqrtPriceX96);
        if (principalValue == 0 || feeValue * 10000 < uint256(minCompoundBps) * principalValue) {
            revert BelowMinCompound();
        }
    }

    function _buildCalls(address wallet, CompoundParams memory p, PlanState memory s)
        internal
        view
        returns (IHiroWallet.Call[] memory calls)
    {
        PlanAmounts memory a = _planAmounts(p, s);

        bool hasProtocolFee = a.protocolFee0 > 0 || a.protocolFee1 > 0;
        bool needsSwap = a.swapAmountIn >= MIN_SWAP_DUST;

        uint256 callCount = 4; // collect-wallet, approve0, approve1, increaseLiquidity
        if (hasProtocolFee) callCount++;
        if (needsSwap) callCount += 2;

        calls = new IHiroWallet.Call[](callCount);
        uint256 i = 0;

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
            IHiroWallet.Call({target: s.token0, value: 0, data: abi.encodeCall(IERC20.approve, (npm, a.incAmt0))});
        calls[i++] =
            IHiroWallet.Call({target: s.token1, value: 0, data: abi.encodeCall(IERC20.approve, (npm, a.incAmt1))});

        calls[i++] = IHiroWallet.Call({
            target: npm,
            value: 0,
            data: abi.encodeCall(
                INonfungiblePositionManager.increaseLiquidity,
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: p.positionId,
                    amount0Desired: a.incAmt0,
                    amount1Desired: a.incAmt1,
                    amount0Min: a.incAmt0Min,
                    amount1Min: a.incAmt1Min,
                    deadline: block.timestamp
                })
            )
        });
    }
}
