// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./HiroWallet.sol";
import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/SafeERC20.sol";

contract HiroFactory is Ownable, IHiroFactory {
    using SafeERC20 for IERC20;

    event HiroCreated(address indexed owner, address indexed wallet);
    event Whitelisted(address indexed addr);
    event RemovedFromWhitelist(address indexed addr);
    event AgentUpdated(address indexed addr, bool isAgent);

    mapping(address => address) public override ownerToWallet;

    mapping(address => bool) private whitelist;
    mapping(address => bool) private agents;

    constructor(address factoryOwner, address[] memory _whitelist, address[] memory _agents) {
        transferOwnership(factoryOwner);

        for (uint256 i = 0; i < _whitelist.length; i++) {
            whitelist[_whitelist[i]] = true;
        }

        for (uint256 i = 0; i < _agents.length; i++) {
            agents[_agents[i]] = true;
        }
    }

    receive() external payable {}

    function createHiroWallet() external payable override returns (address payable) {
        require(ownerToWallet[msg.sender] == address(0), "Subcontract already exists");

        HiroWallet wallet = new HiroWallet{value: msg.value}(msg.sender);

        ownerToWallet[msg.sender] = address(wallet);

        emit HiroCreated(msg.sender, address(wallet));

        return payable(wallet);
    }

    function sweep(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepETH() external override onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    function addToWhitelist(address addr) external override onlyOwner {
        require(addr != address(0), "Invalid address");
        whitelist[addr] = true;

        emit Whitelisted(addr);
    }

    function removeFromWhitelist(address addr) external override onlyOwner {
        require(addr != address(0), "Invalid address");
        whitelist[addr] = false;

        emit RemovedFromWhitelist(addr);
    }

    function isWhitelisted(address addr) external view override returns (bool) {
        return whitelist[addr];
    }

    function getWallet(address owner) external view override returns (address) {
        return ownerToWallet[owner];
    }

    function isAgent(address addr) external view override returns (bool) {
        return agents[addr];
    }

    function setAgent(address addr, bool b) external override onlyOwner {
        agents[addr] = b;
        emit AgentUpdated(addr, b);
    }
}
