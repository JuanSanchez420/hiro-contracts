// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./HiroWallet.sol";
import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/Create2.sol";

contract HiroFactory is Ownable, IHiroFactory {
    using SafeERC20 for IERC20;

    error SubcontractExists();
    error InvalidAddress();
    error EthTransferFailed();
    error Paused();
    error TargetNotWhitelisted();

    event HiroCreated(address indexed owner, address indexed wallet);
    event TargetAdded(address indexed target);
    event TargetRemoved(address indexed target);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event PausedSet(bool paused);

    mapping(address => address) public override ownerToWallet;
    mapping(address => bool) public override targetWhitelist;
    bool public override paused;
    mapping(address => bool) public override agentWhitelist;
    mapping(address => bool) public override strategyWhitelist;

    constructor(address[] memory _initialTargets) {
        for (uint256 i = 0; i < _initialTargets.length; i++) {
            if (_initialTargets[i] == address(0)) revert InvalidAddress();
            targetWhitelist[_initialTargets[i]] = true;
        }
    }

    receive() external payable {}

    function createHiroWallet() external payable override returns (address payable) {
        if (ownerToWallet[msg.sender] != address(0)) revert SubcontractExists();

        bytes32 salt = keccak256(abi.encode(msg.sender));
        bytes memory bytecode = abi.encodePacked(type(HiroWallet).creationCode, abi.encode(msg.sender));
        address wallet = Create2.deploy(msg.value, salt, bytecode);

        ownerToWallet[msg.sender] = wallet;

        emit HiroCreated(msg.sender, wallet);

        return payable(wallet);
    }

    function predictWalletAddress(address owner) external view override returns (address) {
        bytes32 salt = keccak256(abi.encode(owner));
        bytes memory bytecode = abi.encodePacked(type(HiroWallet).creationCode, abi.encode(owner));
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    function getWallet(address owner) external view override returns (address) {
        return ownerToWallet[owner];
    }

    function sweep(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepETH() external override onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
        if (!success) revert EthTransferFailed();
    }

    function validateCall(address target) external view override {
        if (paused) revert Paused();
        if (target == address(this)) return;
        if (!targetWhitelist[target]) revert TargetNotWhitelisted();
    }

    function pause() external override onlyOwner {
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external override onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    function addTarget(address target) external override onlyOwner {
        if (target == address(0)) revert InvalidAddress();
        if (targetWhitelist[target]) return;
        targetWhitelist[target] = true;
        emit TargetAdded(target);
    }

    function removeTarget(address target) external override onlyOwner {
        if (target == address(0)) revert InvalidAddress();
        if (!targetWhitelist[target]) return;
        targetWhitelist[target] = false;
        emit TargetRemoved(target);
    }

    function addAgent(address agent) external override onlyOwner {
        if (agent == address(0)) revert InvalidAddress();
        if (agentWhitelist[agent]) return;
        agentWhitelist[agent] = true;
        emit AgentAdded(agent);
    }

    function removeAgent(address agent) external override onlyOwner {
        if (agent == address(0)) revert InvalidAddress();
        if (!agentWhitelist[agent]) return;
        agentWhitelist[agent] = false;
        emit AgentRemoved(agent);
    }

    function addStrategy(address strategy) external override onlyOwner {
        if (strategy == address(0)) revert InvalidAddress();
        if (strategyWhitelist[strategy]) return;
        strategyWhitelist[strategy] = true;
        emit StrategyAdded(strategy);
    }

    function removeStrategy(address strategy) external override onlyOwner {
        if (strategy == address(0)) revert InvalidAddress();
        if (!strategyWhitelist[strategy]) return;
        strategyWhitelist[strategy] = false;
        emit StrategyRemoved(strategy);
    }
}
