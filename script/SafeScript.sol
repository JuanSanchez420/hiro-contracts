// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import {Script, console} from "lib/forge-std/src/Script.sol";

/// @notice Base contract for deploy scripts. Rejects known test/default
///         addresses when broadcasting to any chain other than Anvil (31337).
abstract contract SafeScript is Script {
    function _rejectDefaultSender() internal view {
        uint256 chainId;
        assembly { chainId := chainid() }
        if (chainId != 31337) {
            require(!_isDefaultAddress(msg.sender), "Deploying from a default/test address on a live chain");
        }
        console.log("Deploying as:", msg.sender);
    }

    function _isDefaultAddress(address addr) internal pure returns (bool) {
        // Foundry default sender
        if (addr == 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38) return true;

        // Anvil/Hardhat HD-wallet accounts (index 0-9)
        if (addr == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) return true;
        if (addr == 0x70997970C51812dc3A010C7d01b50e0d17dc79C8) return true;
        if (addr == 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC) return true;
        if (addr == 0x90F79bf6EB2c4f870365E785982E1f101E93b906) return true;
        if (addr == 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65) return true;
        if (addr == 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc) return true;
        if (addr == 0x976EA74026E726554dB657fA54763abd0C3a0aa9) return true;
        if (addr == 0x14DC79964Da2C08Da15FD353D30d9cBd31045526) return true;
        if (addr == 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f) return true;
        if (addr == 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720) return true;

        return false;
    }
}
