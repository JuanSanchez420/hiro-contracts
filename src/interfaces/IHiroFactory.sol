// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract IHiroFactory {
    function ownerToWallet(address) virtual external view returns (address);
    function price() virtual external view returns (uint256);
    function createHiroWallet(uint256 tokenAmount) virtual external payable;
    function setPrice(uint256 _price) virtual external;
    function getWallet(address owner) virtual external view returns (address);
    function sweep(address token, uint256 amount) virtual external;
    function sweepETH() virtual external;
    function isWhitelisted(address addr) virtual external view returns (bool);
    function addToWhitelist(address addr) virtual external;
    function removeFromWhitelist(address addr) virtual external;
}