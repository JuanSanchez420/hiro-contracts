// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

abstract contract IHiroFactory {
    function ownerToWallet(address) external view virtual returns (address);
    function createHiroWallet() external payable virtual returns (address payable);
    function getWallet(address owner) external view virtual returns (address);
    function sweep(address token, uint256 amount) external virtual;
    function sweepETH() external virtual;
    function isWhitelisted(address addr) external view virtual returns (bool);
    function addToWhitelist(address addr) external virtual;
    function removeFromWhitelist(address addr) external virtual;
    function isAgent(address addr) external view virtual returns (bool);
    function setAgent(address addr, bool b) external virtual;
}
