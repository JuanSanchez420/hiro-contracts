// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {HiroSeason} from "../src/HiroSeason.sol";
import {HiroToken} from "../src/HiroToken.sol";
import "lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "lib/v3-periphery/contracts/interfaces/external/IWETH9.sol";

/// @title SimulateSeason
/// @notice Full season simulation script for HiroSeason
/// @dev Run with: forge script script/SimulateSeason.s.sol --fork-url $BASE_RPC_URL -vvvv
contract SimulateSeason is Script {
    // Base mainnet addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    HiroSeason public season;
    HiroToken public hiroToken;
    ISwapRouter public swapRouter;
    IWETH9 public weth;

    address[] public users;
    uint256[] public userSpentETH;
    uint256[] public userHiroBalances;

    function setUp() public {
        swapRouter = ISwapRouter(SWAP_ROUTER);
        weth = IWETH9(WETH);
    }

    function run() public {
        console.log("=== HiroSeason Full Simulation ===");
        console.log("");

        // 1. Deploy contracts
        console.log("1. Deploying contracts...");
        season = new HiroSeason(WETH, POSITION_MANAGER, SWAP_ROUTER);
        hiroToken = season.hiroToken();
        console.log("   HiroSeason:", address(season));
        console.log("   HiroToken:", address(hiroToken));
        console.log("");

        // 2. Fund redemption pool (20 ETH)
        console.log("2. Funding redemption pool with 20 ETH...");
        season.fundRedemption{value: 20 ether}();
        console.log("   Redemption pool:", season.redemptionPool() / 1e18, "ETH");
        console.log("");

        // 3. Create pool and deploy liquidity
        console.log("3. Creating pool and deploying liquidity...");
        season.createPoolAndDeployLiquidity();
        console.log("   Pool address:", season.pool());
        console.log("   Position token ID:", season.positionTokenId());
        console.log("");

        // 4. Start season
        console.log("4. Starting season...");
        season.startSeason();
        uint256 seasonStart = block.timestamp;
        console.log("   Season started at:", seasonStart);
        console.log("   Season ends at:", season.seasonEndTime());
        console.log("");

        // 5. Create users and simulate buys
        console.log("5. Simulating 10+ users buying HIRO...");
        _createUsers(12);
        _simulateUserBuys(seasonStart);
        console.log("");

        // 6. Owner executes buybacks periodically
        console.log("6. Executing buybacks...");
        _executeBuybacks(seasonStart);
        console.log("");

        // 7. End season after 30 days
        console.log("7. Ending season...");
        vm.warp(seasonStart + 30 days + 1);
        season.endSeason();
        console.log("   Season ended at:", block.timestamp);
        console.log("");

        // 8. Open redemption
        console.log("8. Opening redemption...");
        season.openRedemption(0);
        console.log("   Total redemption ETH:", season.totalRedemptionWETH() / 1e18, "ETH");
        console.log("   Total redeemable HIRO:", season.totalRedeemableHiro() / 1e18, "HIRO");
        console.log("");

        // 9. All users redeem
        console.log("9. Users redeeming HIRO...");
        _simulateRedemptions();
        console.log("");

        // 10. Log statistics
        console.log("10. Final Statistics:");
        _logStatistics();
    }

    function _createUsers(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            address user = vm.addr(i + 100);
            users.push(user);
            userSpentETH.push(0);
            userHiroBalances.push(0);
            vm.deal(user, 50 ether);
        }
        console.log("   Created", count, "users");
    }

    function _simulateUserBuys(uint256 seasonStart) internal {
        uint256 totalVolume = 0;

        for (uint256 i = 0; i < users.length; i++) {
            // Warp to different times during season
            uint256 dayOffset = (i * 2) % 28; // Spread buys across 28 days
            vm.warp(seasonStart + (dayOffset * 1 days));

            // Each user spends different amounts
            uint256 ethAmount = ((i % 5) + 1) * 0.5 ether;

            vm.startPrank(users[i]);

            weth.deposit{value: ethAmount}();
            weth.approve(address(swapRouter), ethAmount);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(hiroToken),
                fee: 3000,
                recipient: users[i],
                deadline: block.timestamp,
                amountIn: ethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            try swapRouter.exactInputSingle(params) returns (uint256 hiroReceived) {
                userSpentETH[i] = ethAmount;
                userHiroBalances[i] = hiroReceived;
                totalVolume += ethAmount;
                console.log("   User %d: %d HIRO for %d ETH", i, hiroReceived / 1e18, ethAmount / 1e18);
            } catch {
                console.log("   User %d swap failed", i);
            }

            vm.stopPrank();
        }

        console.log("   Total trading volume: %d ETH", totalVolume / 1e18);
    }

    function _executeBuybacks(uint256 seasonStart) internal {
        uint256 buybackCount = 0;

        // Execute buybacks at day 10 and day 20
        uint256[] memory buybackDays = new uint256[](2);
        buybackDays[0] = 10;
        buybackDays[1] = 20;

        for (uint256 i = 0; i < buybackDays.length; i++) {
            vm.warp(seasonStart + (buybackDays[i] * 1 days));

            // Add some ETH to simulate accumulated fees
            vm.deal(address(season), address(season).balance + 0.5 ether);

            uint256 available = season.availableForBuyback();
            if (available > 0) {
                try season.executeBuyback() {
                    buybackCount++;
                    console.log("   Buyback %d on day %d: %d ETH", buybackCount, buybackDays[i], available / 1e18);
                } catch {
                    console.log("   Buyback on day %d failed", buybackDays[i]);
                }
            }
        }
    }

    function _simulateRedemptions() internal {
        uint256 totalRedeemed = 0;
        uint256 totalETHReceived = 0;

        for (uint256 i = 0; i < users.length; i++) {
            uint256 userBalance = hiroToken.balanceOf(users[i]);
            if (userBalance > 0) {
                uint256 ethBefore = users[i].balance;

                vm.startPrank(users[i]);
                hiroToken.approve(address(season), userBalance);
                season.redeem(userBalance);
                vm.stopPrank();

                uint256 ethReceived = users[i].balance - ethBefore;
                totalRedeemed += userBalance;
                totalETHReceived += ethReceived;

                console.log("   User %d: %d HIRO -> %d ETH", i, userBalance / 1e18, ethReceived / 1e18);
            }
        }

        console.log("   Total HIRO redeemed: %d", totalRedeemed / 1e18);
        console.log("   Total ETH distributed: %d", totalETHReceived / 1e18);
    }

    function _logStatistics() internal view {
        console.log("   ----------------------------------------");
        console.log("   Season Duration: 30 days");
        console.log("   Initial Redemption Fund: 20 ETH");
        console.log("   Total Supply: 1,000,000,000 HIRO");
        console.log("   Pool Fee: 0.3%%");
        console.log("   Users: %d", users.length);
        console.log("   ----------------------------------------");

        // Calculate totals
        uint256 totalSpent = 0;
        for (uint256 i = 0; i < users.length; i++) {
            totalSpent += userSpentETH[i];
        }
        console.log("   Total ETH spent by users: %d ETH", totalSpent / 1e18);
        console.log("   Final redemption rate: %d", season.calculateRedemption(1 ether) / 1e15);
    }

    receive() external payable {}
}
