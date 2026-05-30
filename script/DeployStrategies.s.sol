// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {UniV3RebalanceStrategy} from "../src/strategies/UniV3RebalanceStrategy.sol";
import {UniV3AutoCompoundStrategy} from "../src/strategies/UniV3AutoCompoundStrategy.sol";

/// @notice Deploys both Uniswap V3 strategies and wires them to an existing HiroFactory.
/// @dev The factory is already live (TX_SECURITY Phase 2), so it is NOT deployed here — its
/// address is read from the `HIRO_FACTORY` env var. NPM/SwapRouter02 are already in
/// `whitelist.json`, so no target-whitelist change is needed. After deploy, the factory
/// owner must run the one-time registration (owner-only, kept out of this script):
///   addStrategy(rebalance), addStrategy(autoCompound), addAgent(<agent EOA>)
contract DeployStrategies is Script {
    // Base mainnet (chain 8453) — same addresses as DeployHiroSeason.s.sol and the fork tests.
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    function run() public {
        address hiroFactory = vm.envAddress("HIRO_FACTORY");
        // Relative auto-compound floor: minimum fees to compound, in bps of position principal.
        // Production default is 1% (100 bps); override with MIN_COMPOUND_BPS for a different pool mix.
        uint16 minCompoundBps = uint16(vm.envOr("MIN_COMPOUND_BPS", uint256(100)));

        vm.startBroadcast();
        UniV3RebalanceStrategy rebalance = new UniV3RebalanceStrategy(NPM, SWAP_ROUTER, V3_FACTORY, hiroFactory);
        UniV3AutoCompoundStrategy autoCompound =
            new UniV3AutoCompoundStrategy(NPM, SWAP_ROUTER, V3_FACTORY, hiroFactory, minCompoundBps);
        vm.stopBroadcast();

        console.log("UniV3RebalanceStrategy deployed at:   ", address(rebalance));
        console.log("UniV3AutoCompoundStrategy deployed at:", address(autoCompound));
        console.log("minCompoundBps:", minCompoundBps);
        console.log("Owner must now call on the factory:");
        console.log("  addStrategy(rebalance); addStrategy(autoCompound); addAgent(<agent EOA>)");
    }
}
