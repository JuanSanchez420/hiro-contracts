// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

abstract contract IHiroFactory {
    function ownerToWallet(address) virtual external view returns (address);
    function createHiroWallet() virtual external payable returns (address payable);
    function getWallet(address owner) virtual external view returns (address);
    function sweep(address token, uint256 amount) virtual external;
    function sweepETH() virtual external;
    function isWhitelisted(address addr) virtual external view returns (bool);
    function addToWhitelist(address addr) virtual external;
    function removeFromWhitelist(address addr) virtual external;
    function isAgent(address addr) virtual external view returns (bool);
    function setAgent(address addr, bool b) virtual external;
}
