// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

abstract contract IHiroFactory {
    function ownerToWallet(address) virtual external view returns (address);
    function transactionPrice() virtual external view returns (uint256);
    function purchasePrice() virtual external view returns (uint256);
    function createHiroWallet(uint256 amountOutMinimum) virtual external payable returns (address payable);
    function swapETHForHiro(uint256 amountOutMinimum, address recipient) virtual external payable returns (uint256 amountOut);
    function setTransactionPrice(uint256 _price) virtual external;
    function getWallet(address owner) virtual external view returns (address);
    function sweep(address token, uint256 amount) virtual external;
    function sweepETH() virtual external;
    function isWhitelisted(address addr) virtual external view returns (bool);
    function addToWhitelist(address addr) virtual external;
    function removeFromWhitelist(address addr) virtual external;
    function isAgent(address addr) virtual external view returns (bool);
    function setAgent(address addr, bool b) virtual external;
}