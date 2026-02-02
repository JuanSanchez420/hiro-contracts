// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./HiroToken.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/math/SafeMath.sol";
import "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "lib/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "lib/v3-core/contracts/libraries/TickMath.sol";

/// @dev SwapRouter02 interface (Base mainnet) - no deadline in struct
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title HiroSeason
/// @notice Seasonal token system where HIRO tokens have a 30-day lifespan
/// @dev At season end, all holders can redeem HIRO for pro-rata ETH. Owner cannot rug.
contract HiroSeason is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════

    enum SeasonState {
        SETUP,
        ACTIVE,
        ENDED,
        REDEEMABLE
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event RedemptionFunded(address indexed funder, uint256 amount);
    event PoolCreated(address indexed pool, uint256 positionTokenId);
    event SeasonStarted(uint256 startTime, uint256 endTime);
    event SeasonEnded(uint256 endTime);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event BuybackExecuted(uint256 ethSpent, uint256 hiroReceived);
    event RedemptionOpened(uint256 totalETH, uint256 totalHiro);
    event Redeemed(address indexed user, uint256 hiroAmount, uint256 ethAmount);
    event BuybackSettingsUpdated(uint256 slippageBps, uint256 priceImpactBps);

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    HiroToken public immutable hiroToken;
    IWETH9 public immutable WETH;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter02 public immutable swapRouter;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18; // 1 billion HIRO
    uint256 public constant SEASON_DURATION = 30 days;
    uint24 public constant POOL_FEE = 3000; // 0.3%
    int24 public constant TICK_SPACING = 60;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    SeasonState public state;
    address public pool;
    uint256 public positionTokenId;

    // Timing
    uint256 public seasonStartTime;

    // Redemption (set once in openRedemption, never modified)
    uint256 public redemptionPool; // Protected WETH (deposit-only during SETUP/ACTIVE/ENDED)
    uint256 public totalRedemptionWETH; // Snapshot at redemption open
    uint256 public totalRedeemableHiro; // Circulating supply at redemption open

    // Token ordering cache
    bool private hiroIsToken0;

    // Buyback settings (in basis points, 100 bps = 1%)
    uint256 public slippageBps = 100; // Default 1%
    uint256 public priceImpactBps = 200; // Default 2%

    // Constants for validation
    uint256 public constant MAX_BPS = 1000; // 10% max
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _weth, address _positionManager, address _swapRouter) {
        WETH = IWETH9(_weth);
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter02(_swapRouter);

        // Deploy HiroToken with entire supply minted to this contract
        hiroToken = new HiroToken(address(this), TOTAL_SUPPLY);

        state = SeasonState.SETUP;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECEIVE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Wrap any incoming ETH to WETH immediately
    receive() external payable {
        if (msg.sender != address(WETH)) {
            WETH.deposit{value: msg.value}();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit ETH to the protected redemption pool (wrapped to WETH)
    /// @dev Can be called in SETUP, ACTIVE, or ENDED states. Funds cannot be withdrawn.
    function fundRedemption() external payable {
        require(
            state == SeasonState.SETUP || state == SeasonState.ACTIVE || state == SeasonState.ENDED,
            "Cannot fund in current state"
        );
        require(msg.value > 0, "Must send ETH");

        WETH.deposit{value: msg.value}();
        redemptionPool = redemptionPool.add(msg.value);

        emit RedemptionFunded(msg.sender, msg.value);
    }

    /// @notice Create HIRO/WETH pool and deploy single-sided HIRO liquidity
    /// @dev Only owner, only in SETUP state
    function createPoolAndDeployLiquidity() external onlyOwner {
        require(state == SeasonState.SETUP, "Not in SETUP state");
        require(pool == address(0), "Pool already created");

        // Determine token ordering and create pool
        hiroIsToken0 = address(hiroToken) < address(WETH);
        (address token0, address token1, uint160 sqrtPriceX96) = _getPoolParams();

        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);

        // Deploy liquidity
        _deployLiquidity(token0, token1, sqrtPriceX96);
    }

    function _getPoolParams() internal view returns (address token0, address token1, uint160 sqrtPriceX96) {
        token0 = hiroIsToken0 ? address(hiroToken) : address(WETH);
        token1 = hiroIsToken0 ? address(WETH) : address(hiroToken);

        // Uniswap V3 single-sided liquidity rules:
        // - current tick < tickLower: only token0 can be deposited
        // - current tick >= tickUpper: only token1 can be deposited
        //
        // For HIRO as token0: liquidity range is tickLower=-99960, tickUpper=0
        // We need current tick < -99960 to deposit only HIRO (token0)
        // Initialize at tick -100020 (below tickLower, aligned to tick spacing 60)
        // sqrtPriceX96 for tick -100020 = 2^96 * 1.0001^(-50010) ≈ 5.28e26
        if (hiroIsToken0) {
            sqrtPriceX96 = 528000000000000000000000000;
        } else {
            // HIRO is token1, liquidity range: tickLower=0, tickUpper=99960
            // We need current tick >= 99960 to deposit only HIRO (token1)
            // Initialize at tick 100020 (above tickUpper, aligned to tick spacing 60)
            // sqrtPriceX96 for tick 100020 = 2^96 * 1.0001^(50010) ≈ 1.18e31
            sqrtPriceX96 = 11876547158554098376954000000000;
        }
    }

    function _deployLiquidity(address token0, address token1, uint160 sqrtPriceX96) internal {
        (int24 tickLower, int24 tickUpper) = _calculateTicks(sqrtPriceX96);

        hiroToken.approve(address(positionManager), TOTAL_SUPPLY);

        uint256 hiroAmount = hiroToken.balanceOf(address(this));
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: hiroIsToken0 ? hiroAmount : 0,
            amount1Desired: hiroIsToken0 ? 0 : hiroAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,,) = positionManager.mint(params);
        positionTokenId = tokenId;

        emit PoolCreated(pool, tokenId);
    }

    function _calculateTicks(uint160) internal view returns (int24 tickLower, int24 tickUpper) {
        // Place liquidity ABOVE current tick for single-sided HIRO deposit
        // Current tick will be ~ -100000
        // Liquidity range: -99960 to 0 (just above current tick)
        // When users buy HIRO with WETH, price rises (tick increases) into the range

        if (hiroIsToken0) {
            // HIRO is token0. Current tick ~ -100000
            // Place liquidity from -99960 to 0 (above current tick)
            tickLower = -99960; // Just above -100000, aligned to 60
            tickUpper = 0;
        } else {
            // HIRO is token1. Current tick ~ 100000
            // Place liquidity from 0 to 99960 (below current tick)
            tickLower = 0;
            tickUpper = 99960; // Just below 100000, aligned to 60
        }
    }

    /// @notice Start the 30-day season
    /// @dev Only owner, only in SETUP state, pool must exist
    function startSeason() external onlyOwner {
        require(state == SeasonState.SETUP, "Not in SETUP state");
        require(pool != address(0), "Pool not created");

        state = SeasonState.ACTIVE;
        seasonStartTime = block.timestamp;

        emit SeasonStarted(block.timestamp, block.timestamp + SEASON_DURATION);
    }

    /// @notice Collect accumulated LP fees (kept as WETH)
    /// @dev Anyone can call in ACTIVE or ENDED state
    function collectFees() external nonReentrant {
        require(state == SeasonState.ACTIVE || state == SeasonState.ENDED, "Not in ACTIVE or ENDED state");

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 amount0, uint256 amount1) = positionManager.collect(params);

        emit FeesCollected(amount0, amount1);
    }

    /// @notice Update buyback slippage and price impact settings
    /// @param _slippageBps Slippage tolerance (100 = 1%)
    /// @param _priceImpactBps Price impact limit (200 = 2%)
    function setBuybackSettings(uint256 _slippageBps, uint256 _priceImpactBps) external onlyOwner {
        require(_slippageBps <= MAX_BPS, "Slippage too high");
        require(_priceImpactBps <= MAX_BPS, "Price impact too high");

        slippageBps = _slippageBps;
        priceImpactBps = _priceImpactBps;

        emit BuybackSettingsUpdated(_slippageBps, _priceImpactBps);
    }

    /// @notice Get current pool sqrt price
    function _getCurrentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Calculate expected HIRO output for WETH input at current price
    function _calculateExpectedHiro(uint256 wethAmount) internal view returns (uint256) {
        uint160 sqrtPriceX96 = _getCurrentSqrtPrice();

        // sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // We need to calculate HIRO out for WETH in

        if (hiroIsToken0) {
            // HIRO=token0, WETH=token1. price = WETH/HIRO
            // HIRO = WETH * 2^192 / sqrtPrice^2
            return wethAmount.mul(uint256(1) << 96).div(uint256(sqrtPriceX96)).mul(uint256(1) << 96).div(
                uint256(sqrtPriceX96)
            );
        } else {
            // WETH=token0, HIRO=token1. price = HIRO/WETH
            // HIRO = WETH * sqrtPrice^2 / 2^192
            return wethAmount.mul(uint256(sqrtPriceX96)).div(uint256(1) << 96).mul(uint256(sqrtPriceX96)).div(
                uint256(1) << 96
            );
        }
    }

    /// @notice Calculate price limit for buyback based on priceImpactBps
    function _calculatePriceLimit() internal view returns (uint160) {
        uint160 currentSqrtPrice = _getCurrentSqrtPrice();

        // For WETH->HIRO:
        // - hiroIsToken0 (zeroForOne=false): price goes UP, limit > current
        // - !hiroIsToken0 (zeroForOne=true): price goes DOWN, limit < current
        // Price impact of X% means sqrt price moves by ~X/2%

        if (hiroIsToken0) {
            // Limit is higher price (buying pushes price up)
            uint256 adjusted =
                uint256(currentSqrtPrice).mul(BPS_DENOMINATOR.add(priceImpactBps.div(2))).div(BPS_DENOMINATOR);
            return adjusted >= TickMath.MAX_SQRT_RATIO ? uint160(TickMath.MAX_SQRT_RATIO - 1) : uint160(adjusted);
        } else {
            // Limit is lower price (buying pushes price down)
            uint256 adjusted =
                uint256(currentSqrtPrice).mul(BPS_DENOMINATOR.sub(priceImpactBps.div(2))).div(BPS_DENOMINATOR);
            return adjusted <= TickMath.MIN_SQRT_RATIO ? uint160(TickMath.MIN_SQRT_RATIO + 1) : uint160(adjusted);
        }
    }

    /// @notice Execute a buyback: swap available WETH for HIRO
    /// @dev Only owner, only in ACTIVE state. Uses on-chain slippage/price impact settings.
    function executeBuyback() external onlyOwner nonReentrant {
        require(state == SeasonState.ACTIVE, "Not in ACTIVE state");

        uint256 available = WETH.balanceOf(address(this)).sub(redemptionPool);
        require(available > 0, "No WETH available for buyback");

        // Calculate expected output and apply slippage
        uint256 expectedHiro = _calculateExpectedHiro(available);
        uint256 expectedAfterFee = expectedHiro.mul(997).div(1000); // 0.3% pool fee
        uint256 minHiroOut = expectedAfterFee.mul(BPS_DENOMINATOR.sub(slippageBps)).div(BPS_DENOMINATOR);

        // Calculate price impact limit
        uint160 sqrtPriceLimit = _calculatePriceLimit();

        WETH.approve(address(swapRouter), available);

        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(hiroToken),
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: available,
            amountOutMinimum: minHiroOut,
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        uint256 hiroReceived = swapRouter.exactInputSingle(params);

        emit BuybackExecuted(available, hiroReceived);
    }

    /// @notice End the season after 30 days
    /// @dev Anyone can call after SEASON_DURATION has passed
    function endSeason() external {
        require(state == SeasonState.ACTIVE, "Not in ACTIVE state");
        require(block.timestamp >= seasonStartTime + SEASON_DURATION, "Season not over");

        state = SeasonState.ENDED;

        emit SeasonEnded(block.timestamp);
    }

    /// @notice Open redemption: pull LP, burn contract HIRO, set redemption math
    /// @param minWethOut Minimum WETH to receive from LP withdrawal (slippage protection)
    /// @dev Anyone can call in ENDED state. Pass 0 for minWethOut if no slippage protection needed.
    function openRedemption(uint256 minWethOut) external nonReentrant {
        require(state == SeasonState.ENDED, "Not in ENDED state");

        _withdrawLiquidity(minWethOut);
        _collect();
        _burnContractHiro();
        _finalizeRedemption();
    }

    function _withdrawLiquidity(uint256 minWethOut) internal {
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(positionTokenId);

        if (liquidity > 0) {
            // Determine which amount corresponds to WETH based on token ordering
            uint256 amount0Min = hiroIsToken0 ? 0 : minWethOut;
            uint256 amount1Min = hiroIsToken0 ? minWethOut : 0;

            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: positionTokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                })
            );
        }
    }

    function _collect() internal {
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function _burnContractHiro() internal {
        uint256 contractHiroBalance = hiroToken.balanceOf(address(this));
        if (contractHiroBalance > 0) {
            hiroToken.burn(contractHiroBalance);
        }
    }

    function _finalizeRedemption() internal {
        totalRedeemableHiro = hiroToken.totalSupply();
        totalRedemptionWETH = WETH.balanceOf(address(this));
        state = SeasonState.REDEEMABLE;

        emit RedemptionOpened(totalRedemptionWETH, totalRedeemableHiro);
    }

    /// @notice Redeem HIRO for pro-rata ETH
    /// @param hiroAmount Amount of HIRO to redeem
    /// @dev Anyone with HIRO can call in REDEEMABLE state. Fixed rate for all.
    function redeem(uint256 hiroAmount) external nonReentrant {
        require(state == SeasonState.REDEEMABLE, "Not in REDEEMABLE state");
        require(hiroAmount > 0, "Must redeem > 0");
        require(totalRedeemableHiro > 0, "No HIRO to redeem");

        // Calculate amount owed: (hiroAmount / totalRedeemableHiro) * totalRedemptionWETH
        uint256 amountOwed = hiroAmount.mul(totalRedemptionWETH).div(totalRedeemableHiro);
        require(amountOwed > 0, "Amount too small");

        // Burn user's HIRO (requires approval)
        hiroToken.burnFrom(msg.sender, hiroAmount);

        // Unwrap WETH and send ETH to user
        WETH.withdraw(amountOwed);
        (bool success,) = msg.sender.call{value: amountOwed}("");
        require(success, "ETH transfer failed");

        emit Redeemed(msg.sender, hiroAmount, amountOwed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get the season end time
    function seasonEndTime() external view returns (uint256) {
        if (seasonStartTime == 0) return 0;
        return seasonStartTime + SEASON_DURATION;
    }

    /// @notice Get available WETH for buybacks (balance minus protected redemption pool)
    function availableForBuyback() external view returns (uint256) {
        uint256 balance = WETH.balanceOf(address(this));
        if (balance <= redemptionPool) return 0;
        return balance.sub(redemptionPool);
    }

    /// @notice Calculate ETH amount for a given HIRO redemption
    function calculateRedemption(uint256 hiroAmount) external view returns (uint256) {
        if (state != SeasonState.REDEEMABLE || totalRedeemableHiro == 0) return 0;
        return hiroAmount.mul(totalRedemptionWETH).div(totalRedeemableHiro);
    }

    /// @notice Get current LP position liquidity (for calculating minWethOut off-chain)
    function getPositionLiquidity() external view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(positionTokenId);
    }

    /// @notice Preview buyback parameters without executing
    function previewBuyback()
        external
        view
        returns (uint256 available, uint256 expectedHiro, uint256 minHiroOut, uint160 sqrtPriceLimit)
    {
        available = WETH.balanceOf(address(this)).sub(redemptionPool);
        if (available == 0 || pool == address(0)) return (0, 0, 0, 0);

        expectedHiro = _calculateExpectedHiro(available);
        uint256 expectedAfterFee = expectedHiro.mul(997).div(1000);
        minHiroOut = expectedAfterFee.mul(BPS_DENOMINATOR.sub(slippageBps)).div(BPS_DENOMINATOR);
        sqrtPriceLimit = _calculatePriceLimit();
    }

    /// @notice Get current HIRO price in WETH (scaled by 1e18)
    function getCurrentHiroPrice() external view returns (uint256 price) {
        if (pool == address(0)) return 0;
        uint160 sqrtPriceX96 = _getCurrentSqrtPrice();

        // Return HIRO per WETH (how much HIRO you get for 1 WETH)
        if (hiroIsToken0) {
            return uint256(1e18).mul(uint256(1) << 96).div(uint256(sqrtPriceX96)).mul(uint256(1) << 96).div(
                uint256(sqrtPriceX96)
            );
        } else {
            return uint256(1e18).mul(uint256(sqrtPriceX96)).div(uint256(1) << 96).mul(uint256(sqrtPriceX96)).div(
                uint256(1) << 96
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC721 RECEIVER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Handle receiving LP NFT from position manager
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
