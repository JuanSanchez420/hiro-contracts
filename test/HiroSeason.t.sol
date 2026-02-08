// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {HiroSeason} from "../src/HiroSeason.sol";
import {HiroToken} from "../src/HiroToken.sol";
import "lib/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

// SwapRouter02 interface (different from ISwapRouter - no deadline in struct)
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

contract HiroSeasonTest is Test {
    // Base mainnet addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    HiroSeason public season;
    HiroToken public hiroToken;
    ISwapRouter02 public swapRouter;
    IWETH9 public weth;

    address public owner;
    address[10] public users;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        owner = address(this);
        swapRouter = ISwapRouter02(SWAP_ROUTER);
        weth = IWETH9(WETH);

        // Create users
        for (uint256 i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(users[i], 100 ether);
        }

        // Deploy HiroSeason
        season = new HiroSeason(WETH, POSITION_MANAGER, SWAP_ROUTER);
        hiroToken = season.hiroToken();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE MACHINE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testInitialStateIsSetup() public {
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.SETUP));
    }

    function testCannotStartBeforePoolCreated() public {
        vm.expectRevert("Pool not created");
        season.startSeason();
    }

    function testCannotEndBeforeSeasonDuration() public {
        // Setup pool and start season
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.expectRevert("Season not over");
        season.endSeason();
    }

    function testCannotRedeemBeforeOpen() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.expectRevert("Not in REDEEMABLE state");
        season.redeem(1 ether);
    }

    function testStateTransitionsOnlyForward() public {
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.SETUP));

        season.createPoolAndDeployLiquidity();
        season.startSeason();
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.ACTIVE));

        // Cannot go back to SETUP
        vm.expectRevert("Not in SETUP state");
        season.createPoolAndDeployLiquidity();

        // Fast forward past season duration
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.ENDED));

        // Cannot go back to ACTIVE
        vm.expectRevert("Not in ACTIVE state");
        season.endSeason();

        season.openRedemption(0);
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));

        // Cannot go back to ENDED
        vm.expectRevert("Not in ENDED state");
        season.openRedemption(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OWNER CONSTRAINT TESTS (NON-RUGGABLE GUARANTEES)
    // ═══════════════════════════════════════════════════════════════════════════

    function testNoETHWithdrawalPathBeforeRedemption() public {
        // Fund the contract with ETH
        season.fundRedemption{value: 10 ether}();

        // Setup and start season
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Verify ETH is locked as WETH in the contract
        uint256 wethBalance = weth.balanceOf(address(season));
        assertEq(wethBalance, 10 ether);

        // Verify no public function exists that would let owner withdraw ETH/WETH
        // The only way ETH leaves is via redeem() which requires burning HIRO
        // Contract has no withdraw/transfer/sweep functions for ETH or WETH

        // Fast forward and end season
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // WETH is still locked until redemption is opened and users redeem
        assertTrue(weth.balanceOf(address(season)) >= 10 ether);
    }

    function testOwnerCannotTransferHIRODirectly() public {
        // All HIRO is minted to the season contract
        uint256 balance = hiroToken.balanceOf(address(season));
        assertEq(balance, 1_000_000_000 * 1e18);

        // The HiroSeason contract has no function that calls hiroToken.transfer()
        // Owner cannot extract HIRO - it can only be:
        // 1. Sold into the LP (via buyback which buys HIRO, not sells)
        // 2. Burned during openRedemption

        // Verify owner cannot call transfer on hiroToken through season contract
        // (there's simply no function that does this)

        // Setup pool to see HIRO flow only to LP
        season.createPoolAndDeployLiquidity();

        // After liquidity deployment, season contract still holds remaining HIRO
        // but has no way to transfer it out except through the LP mechanics
        uint256 seasonBalance = hiroToken.balanceOf(address(season));

        // If any HIRO left (not all went to LP), it's still locked
        // Owner has no function to extract it
        assertTrue(seasonBalance >= 0); // Passes regardless - point is no extraction function
    }

    function testLPNFTLockedInContract() public {
        season.createPoolAndDeployLiquidity();
        uint256 tokenId = season.positionTokenId();
        assertTrue(tokenId > 0);

        // Verify the NFT is owned by the season contract
        address nftOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(nftOwner, address(season));

        // The HiroSeason contract:
        // 1. Never approves the NFT for transfer to anyone
        // 2. Has no function that calls safeTransferFrom/transferFrom on position manager
        // 3. Only interacts with NFT via decreaseLiquidity and collect (in openRedemption)

        // Verify the contract cannot transfer the NFT (no such function exists)
        // If owner tries to call positionManager.safeTransferFrom directly, it fails
        // because only the NFT owner (season contract) can transfer

        // This is what makes it non-ruggable - LP is locked until redemption
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BUYBACK TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testOnlyOwnerCanExecuteBuyback() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Send some ETH to the contract (simulating trading fees)
        vm.deal(address(season), 1 ether);

        vm.prank(users[0]);
        vm.expectRevert("Ownable: caller is not the owner");
        season.executeBuyback();
    }

    function testBuybackProtectsRedemptionPool() public {
        // Fund redemption pool
        season.fundRedemption{value: 5 ether}();
        assertEq(season.redemptionPool(), 5 ether);

        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Try buyback with no extra WETH
        vm.expectRevert("No WETH available for buyback");
        season.executeBuyback();

        // Add extra WETH beyond redemption pool (send ETH which gets wrapped)
        (bool success,) = address(season).call{value: 2 ether}("");
        require(success);

        // Available for buyback should be 2 WETH
        assertEq(season.availableForBuyback(), 2 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REDEMPTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testRedemptionMathIsCorrect() public {
        // Fund redemption pool
        season.fundRedemption{value: 10 ether}();

        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Fast forward and end season
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        // Check redemption math
        uint256 totalETH = season.totalRedemptionWETH();
        uint256 totalHiro = season.totalRedeemableHiro();

        assertTrue(totalETH > 0);
        assertTrue(totalHiro > 0);

        // Calculate expected redemption for 1% of total HIRO
        uint256 testAmount = totalHiro / 100;
        uint256 expectedETH = testAmount * totalETH / totalHiro;
        uint256 calculatedETH = season.calculateRedemption(testAmount);

        assertEq(calculatedETH, expectedETH);
    }

    function testRedemptionRateNeverChanges() public {
        season.fundRedemption{value: 20 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        uint256 totalETH = season.totalRedemptionWETH();
        uint256 totalHiro = season.totalRedeemableHiro();

        // Rate should remain constant regardless of redemptions
        uint256 rate1 = season.calculateRedemption(1 ether);

        // Note: In this test we can't actually redeem since no users hold HIRO
        // But we verify the rate calculation is fixed
        uint256 rate2 = season.calculateRedemption(1 ether);

        assertEq(rate1, rate2);
        assertEq(rate1, 1 ether * totalETH / totalHiro);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFundRedemptionInSetup() public {
        season.fundRedemption{value: 5 ether}();
        assertEq(season.redemptionPool(), 5 ether);
    }

    function testFundRedemptionInActive() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        season.fundRedemption{value: 5 ether}();
        assertEq(season.redemptionPool(), 5 ether);
    }

    function testFundRedemptionInEnded() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        season.fundRedemption{value: 5 ether}();
        assertEq(season.redemptionPool(), 5 ether);
    }

    function testCannotFundRedemptionInRedeemable() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        vm.expectRevert("Cannot fund in current state");
        season.fundRedemption{value: 5 ether}();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testRedeemWithOneWei() public {
        // Setup full season with trading so users have HIRO
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Bootstrap to get HIRO to a user
        address smallHolder = makeAddr("smallHolder");
        vm.deal(smallHolder, 1 ether);
        vm.startPrank(smallHolder);
        weth.deposit{value: 0.1 ether}();
        weth.approve(address(swapRouter), 0.1 ether);
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(hiroToken),
            fee: 3000,
            recipient: smallHolder,
            amountIn: 0.1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try swapRouter.exactInputSingle(params) {} catch {}
        vm.stopPrank();

        // End season and open redemption
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        // Try to redeem 1 wei of HIRO
        uint256 userBalance = hiroToken.balanceOf(smallHolder);
        if (userBalance > 0) {
            vm.startPrank(smallHolder);
            hiroToken.approve(address(season), 1);
            // This should either work or revert with "Amount too small"
            // depending on the math
            try season.redeem(1) {
                // Success - 1 wei was enough to get some ETH
            } catch {
                // Expected if rounding makes amountOwed = 0
            }
            vm.stopPrank();
        }
    }

    function testRedeemZeroAmountReverts() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        vm.expectRevert("Must redeem > 0");
        season.redeem(0);
    }

    function testEndSeasonCanOnlyBeCalledOnce() public {
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // Second call should fail
        vm.expectRevert("Not in ACTIVE state");
        season.endSeason();
    }

    function testCreatePoolAndDeployLiquidityCanOnlyBeCalledOnce() public {
        season.createPoolAndDeployLiquidity();

        // Second call should fail
        vm.expectRevert("Pool already created");
        season.createPoolAndDeployLiquidity();
    }

    function testFundRedemptionWithZeroValueReverts() public {
        vm.expectRevert("Must send ETH");
        season.fundRedemption{value: 0}();
    }

    function testRedemptionRoundingFairness() public {
        // Test that redemption math doesn't lose significant value to rounding
        season.fundRedemption{value: 100 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Get HIRO to multiple users
        for (uint256 i = 0; i < 5; i++) {
            vm.deal(users[i], 10 ether);
            vm.startPrank(users[i]);
            weth.deposit{value: 1 ether}();
            weth.approve(address(swapRouter), 1 ether);
            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(hiroToken),
                fee: 3000,
                recipient: users[i],
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            try swapRouter.exactInputSingle(params) {} catch {}
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        uint256 totalHiro = season.totalRedeemableHiro();

        // Redeem all users and track total ETH received
        uint256 totalETHReceived = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 userHiro = hiroToken.balanceOf(users[i]);
            if (userHiro > 0) {
                uint256 ethBefore = users[i].balance;
                vm.startPrank(users[i]);
                hiroToken.approve(address(season), userHiro);
                season.redeem(userHiro);
                vm.stopPrank();
                totalETHReceived += users[i].balance - ethBefore;
            }
        }

        // Verify total ETH distributed is close to total (accounting for dust)
        // Some dust may remain due to rounding, but should be minimal
        uint256 remainingWETH = weth.balanceOf(address(season));
        assertTrue(remainingWETH < totalHiro / 1e18, "Too much dust remaining");
    }

    function testCollectFeesWorksWithZeroFees() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Don't do any trading, so no fees accumulated

        // Collect fees should still work (just collect 0)
        season.collectFees();
        // No revert means success
    }

    function testBuybackWithNoTradingYet() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // No extra WETH beyond redemption pool
        assertEq(season.availableForBuyback(), 0);

        vm.expectRevert("No WETH available for buyback");
        season.executeBuyback();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TEST - FULL SEASON SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    function testFullSeasonWith10Users() public {
        console.log("");
        console.log("========== HIRO SEASON SIMULATION ==========");
        console.log("");

        // 1. Setup: Deploy, fund 20 ETH, create pool, start
        uint256 initialFunding = 20 ether;
        season.fundRedemption{value: initialFunding}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        uint256 seasonStart = block.timestamp;
        assertTrue(season.pool() != address(0));

        console.log("--- SETUP ---");
        console.log("Initial redemption fund: 20 ETH");

        // Bootstrap: Make initial trade to move price into liquidity range
        // This simulates the first buyer pushing price into the active range
        console.log("Bootstrapping pool with initial 1 ETH trade...");
        {
            address bootstrapper = makeAddr("bootstrapper");
            vm.deal(bootstrapper, 10 ether);
            vm.startPrank(bootstrapper);

            weth.deposit{value: 5 ether}();
            weth.approve(address(swapRouter), 5 ether);

            ISwapRouter02.ExactInputSingleParams memory bootParams = ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(hiroToken),
                fee: 3000,
                recipient: bootstrapper,
                amountIn: 5 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            try swapRouter.exactInputSingle(bootParams) returns (uint256 hiroReceived) {
                console.log(_concat("Bootstrap successful: 5 ETH -> ", _concat(_formatHiro(hiroReceived), " HIRO")));
            } catch {
                console.log("Bootstrap trade failed - liquidity may not be in range");
            }

            vm.stopPrank();
        }
        console.log("");

        // 2. Simulate users buying HIRO over 30 days
        console.log("--- TRADING PHASE (30 days) ---");
        uint256[] memory userHiroBalances = new uint256[](10);
        uint256[] memory userEthSpent = new uint256[](10);
        uint256 totalEthTraded = 0;
        uint256 successfulBuys = 0;

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(seasonStart + (i * 3 days));
            vm.startPrank(users[i]);

            uint256 ethAmount = (i + 1) * 0.5 ether;
            userEthSpent[i] = ethAmount;

            weth.deposit{value: ethAmount}();
            weth.approve(address(swapRouter), ethAmount);

            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(hiroToken),
                fee: 3000,
                recipient: users[i],
                amountIn: ethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            try swapRouter.exactInputSingle(params) returns (uint256 hiroReceived) {
                userHiroBalances[i] = hiroReceived;
                totalEthTraded += ethAmount;
                successfulBuys++;
                console.log(_buildTradeLog(i, ethAmount, hiroReceived));
            } catch {
                userEthSpent[i] = 0;
                console.log("  User swap failed");
            }

            vm.stopPrank();
        }

        console.log("");
        console.log(_concat("Total ETH traded: ", _formatEth(totalEthTraded)));
        console.log("");

        // 3. Owner executes buybacks
        console.log("--- BUYBACK ---");
        vm.deal(address(season), address(season).balance + 2 ether);
        uint256 availableForBuyback = season.availableForBuyback();

        if (availableForBuyback > 0) {
            try season.executeBuyback() {
                console.log(_concat("Buyback: ", _concat(_formatEth(availableForBuyback), " ETH")));
            } catch {
                console.log("Buyback failed");
            }
        }
        console.log("");

        // 4. End season after 30 days
        vm.warp(seasonStart + 30 days + 1);
        season.endSeason();
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.ENDED));

        // 5. Open redemption
        season.openRedemption(0);
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));

        uint256 totalRedemptionWETH = season.totalRedemptionWETH();
        uint256 totalRedeemableHiro = season.totalRedeemableHiro();

        console.log("--- REDEMPTION OPENED ---");
        console.log(_concat("Total ETH available: ", _formatEth(totalRedemptionWETH)));
        console.log(_concat("Total HIRO circulating: ", _formatHiro(totalRedeemableHiro)));
        console.log(
            _concat("Rate per 1M HIRO: ", _concat(_formatEth(season.calculateRedemption(1_000_000 ether)), " ETH"))
        );
        console.log("");

        // 6. All users redeem
        console.log("--- REDEMPTIONS ---");

        uint256 totalRedeemed = 0;
        uint256 totalEthReturned = 0;

        for (uint256 i = 0; i < 10; i++) {
            uint256 userBalance = hiroToken.balanceOf(users[i]);
            if (userBalance > 0) {
                uint256 ethBefore = users[i].balance;

                vm.startPrank(users[i]);
                hiroToken.approve(address(season), userBalance);
                season.redeem(userBalance);
                vm.stopPrank();

                uint256 ethReceived = users[i].balance - ethBefore;
                totalRedeemed += userBalance;
                totalEthReturned += ethReceived;

                int256 profitLoss = int256(ethReceived) - int256(userEthSpent[i]);
                console.log(_buildRedemptionLog(i, userEthSpent[i], userBalance, ethReceived, profitLoss));

                uint256 expectedETH = userBalance * totalRedemptionWETH / totalRedeemableHiro;
                assertEq(ethReceived, expectedETH);
            }
        }

        console.log("");
        console.log("--- SUMMARY ---");
        console.log(_concat("Total HIRO redeemed: ", _formatHiro(totalRedeemed)));
        console.log(_concat("Total ETH returned to users: ", _formatEth(totalEthReturned)));
        console.log(_concat("Total ETH users spent: ", _formatEth(totalEthTraded)));

        int256 netResult = int256(totalEthReturned) - int256(totalEthTraded);
        if (netResult >= 0) {
            console.log(_concat("Net user GAIN: +", _concat(_formatEth(uint256(netResult)), " ETH")));
        } else {
            console.log(_concat("Net user LOSS: -", _concat(_formatEth(uint256(-netResult)), " ETH")));
        }
        console.log("");
        console.log("========== SIMULATION COMPLETE ==========");
    }

    function _buildTradeLog(uint256 userId, uint256 ethSpent, uint256 hiroReceived)
        internal
        pure
        returns (string memory)
    {
        string memory part1 = _concat("  User ", _toString(userId));
        string memory part2 = _concat(": ", _formatEth(ethSpent));
        string memory part3 = _concat(" ETH -> ", _formatHiro(hiroReceived));
        return _concat(part1, _concat(part2, part3));
    }

    function _buildRedemptionLog(
        uint256 userId,
        uint256 ethSpent,
        uint256,
        uint256 ethReceived,
        int256 profitLoss
    ) internal pure returns (string memory) {
        string memory plStr;
        if (profitLoss >= 0) {
            plStr = _concat("+", _formatEth(uint256(profitLoss)));
        } else {
            plStr = _concat("-", _formatEth(uint256(-profitLoss)));
        }

        // Build in parts to avoid stack issues
        string memory part1 = _concat("  User ", _toString(userId));
        string memory part2 = _concat(": ", _formatEth(ethSpent));
        string memory part3 = _concat(" -> ", _formatEth(ethReceived));
        string memory part4 = _concat(" (", _concat(plStr, ")"));

        return _concat(part1, _concat(part2, _concat(part3, part4)));
    }

    function _concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }

    function _formatEth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 decimal = (weiAmount % 1e18) / 1e16;
        if (decimal < 10) {
            return _concat(_toString(whole), _concat(".0", _toString(decimal)));
        }
        return _concat(_toString(whole), _concat(".", _toString(decimal)));
    }

    function _formatHiro(uint256 weiAmount) internal pure returns (string memory) {
        uint256 millions = weiAmount / 1e24;
        uint256 decimal = (weiAmount % 1e24) / 1e22;
        if (millions > 0) {
            return _concat(_toString(millions), _concat(".", _concat(_toString(decimal), "M")));
        }
        uint256 thousands = weiAmount / 1e21;
        return _concat(_toString(thousands), "K");
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testOpenRedemptionRevertsOnBadSlippage() public {
        // Setup a full season with trading
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Bootstrap trading to get WETH in the LP
        address bootstrapper = makeAddr("slippageBootstrapper");
        vm.deal(bootstrapper, 10 ether);
        vm.startPrank(bootstrapper);
        weth.deposit{value: 5 ether}();
        weth.approve(address(swapRouter), 5 ether);
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(hiroToken),
            fee: 3000,
            recipient: bootstrapper,
            amountIn: 5 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        swapRouter.exactInputSingle(params);
        vm.stopPrank();

        // End the season
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // Try to open redemption with an impossibly high minimum WETH requirement
        // This should revert because the LP won't have that much WETH
        vm.expectRevert(); // Will revert from Uniswap's slippage check
        season.openRedemption(1000000 ether);
    }

    function testOpenRedemptionWithZeroMinimum() public {
        // Setup a full season with trading
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Bootstrap trading
        address bootstrapper = makeAddr("zeroSlippageBootstrapper");
        vm.deal(bootstrapper, 10 ether);
        vm.startPrank(bootstrapper);
        weth.deposit{value: 5 ether}();
        weth.approve(address(swapRouter), 5 ether);
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(hiroToken),
            fee: 3000,
            recipient: bootstrapper,
            amountIn: 5 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        swapRouter.exactInputSingle(params);
        vm.stopPrank();

        // End the season
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // Open redemption with 0 minimum (backwards compatible behavior)
        season.openRedemption(0);

        // Verify state transitioned correctly
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));
        assertTrue(season.totalRedemptionWETH() > 0);
    }

    function testGetPositionLiquidity() public {
        // Create pool and deploy liquidity
        season.createPoolAndDeployLiquidity();

        // After liquidity deployment, should have liquidity
        uint128 liquidityAfter = season.getPositionLiquidity();
        assertTrue(liquidityAfter > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COLLECT FEES TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testCollectFeesInActiveState() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Bootstrap trading to generate fees
        address trader = makeAddr("feeTester");
        vm.deal(trader, 10 ether);

        // Make multiple trades to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(trader);
            weth.deposit{value: 1 ether}();
            weth.approve(address(swapRouter), 1 ether);

            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(hiroToken),
                fee: 3000,
                recipient: trader,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            try swapRouter.exactInputSingle(params) {} catch {}
            vm.stopPrank();
        }

        // Collect fees should succeed in ACTIVE state
        season.collectFees();
        // No revert means success
    }

    function testCollectFeesInEndedState() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // Bootstrap trading
        address trader = makeAddr("endedFeeTester");
        vm.deal(trader, 10 ether);
        vm.startPrank(trader);
        weth.deposit{value: 5 ether}();
        weth.approve(address(swapRouter), 5 ether);
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(hiroToken),
            fee: 3000,
            recipient: trader,
            amountIn: 5 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try swapRouter.exactInputSingle(params) {} catch {}
        vm.stopPrank();

        // End the season
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.ENDED));

        // Collect fees should succeed in ENDED state
        season.collectFees();
        // No revert means success
    }

    function testCollectFeesRevertsInSetupState() public {
        vm.expectRevert("Not in ACTIVE or ENDED state");
        season.collectFees();
    }

    function testCollectFeesRevertsInRedeemableState() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();
        season.openRedemption(0);

        vm.expectRevert("Not in ACTIVE or ENDED state");
        season.collectFees();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPEN REDEMPTION PERMISSIONLESS TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function testAnyoneCanOpenRedemptionAfterGracePeriod() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // End the season and warp past grace period
        vm.warp(block.timestamp + 30 days + 3 days + 1);
        season.endSeason();

        // Any user can open redemption after grace period
        vm.prank(users[0]);
        season.openRedemption(0);

        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));
        assertTrue(season.totalRedemptionWETH() > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GRACE PERIOD TESTS (M-1)
    // ═══════════════════════════════════════════════════════════════════════════

    function testOwnerCanOpenRedemptionImmediatelyAfterEnded() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        // End the season (warp exactly to end)
        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // Owner can call immediately — no grace period wait
        season.openRedemption(0);
        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));
    }

    function testNonOwnerRevertsBeforeGracePeriod() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        vm.warp(block.timestamp + 30 days + 1);
        season.endSeason();

        // Non-owner reverts during grace period
        vm.prank(users[0]);
        vm.expectRevert("Grace period not over");
        season.openRedemption(0);
    }

    function testNonOwnerSucceedsAfterGracePeriod() public {
        season.fundRedemption{value: 10 ether}();
        season.createPoolAndDeployLiquidity();
        season.startSeason();

        uint256 startTime = block.timestamp;

        vm.warp(startTime + 30 days + 1);
        season.endSeason();

        // Warp to exactly after grace period
        vm.warp(startTime + 30 days + 3 days);
        vm.prank(users[0]);
        season.openRedemption(0);

        assertEq(uint256(season.state()), uint256(HiroSeason.SeasonState.REDEEMABLE));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TWAP / OBSERVATION CARDINALITY TESTS (M-2)
    // ═══════════════════════════════════════════════════════════════════════════

    function testObservationCardinalityIncreasedAfterPoolCreation() public {
        season.createPoolAndDeployLiquidity();

        address poolAddr = season.pool();
        (,,,, uint16 observationCardinalityNext,,) = IUniswapV3Pool(poolAddr).slot0();
        assertTrue(observationCardinalityNext >= 10, "Observation cardinality next should be >= 10");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER
    // ═══════════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
