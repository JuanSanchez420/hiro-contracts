// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHiroFactory {
    function ownerToWallet(address) external view returns (address);
    function createHiroWallet() external payable returns (address payable);
    function getWallet(address owner) external view returns (address);
    function predictWalletAddress(address owner) external view returns (address);

    function sweep(address token, uint256 amount) external;
    function sweepETH() external;

    function targetWhitelist(address) external view returns (bool);
    function validateCall(address target) external view;
    function paused() external view returns (bool);

    function pause() external;
    function unpause() external;
    function addTarget(address target) external;
    function removeTarget(address target) external;

    function agentWhitelist(address) external view returns (bool);
    function strategyWhitelist(address) external view returns (bool);

    function addAgent(address agent) external;
    function removeAgent(address agent) external;
    function addStrategy(address strategy) external;
    function removeStrategy(address strategy) external;
}
