// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title Interface for WETH9
/// @dev Vendored locally so it can compile under ^0.8.20; the upstream
/// `lib/v3-periphery/contracts/interfaces/external/IWETH9.sol` is pinned to =0.7.6.
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}
