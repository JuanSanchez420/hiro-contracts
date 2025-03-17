// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./HiroWallet.sol";
import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract HiroFactory is Ownable, IHiroFactory, ReentrancyGuard {
    event TransactionPriceSet(uint256 price);
    event HiroCreated(address indexed owner, address indexed wallet);
    event Whitelisted(address indexed addr);
    event RemovedFromWhitelist(address indexed addr);

    mapping(address => address) public override ownerToWallet;

    mapping(address => bool) private whitelist;
    mapping(address => bool) private agents;

    uint256 public override transactionPrice; // basis points
    uint256 public immutable override purchasePrice = 10_000_000_000_000_000; // 0.01 ETH

    receive() external payable {}

    constructor(
        uint256 _transactionPrice,
        address factoryOwner,
        address[] memory _whitelist,
        address[] memory _agents
    ) {
        transactionPrice = _transactionPrice;
        transferOwnership(factoryOwner);

        for (uint i = 0; i < _whitelist.length; i++) {
            whitelist[_whitelist[i]] = true;
        }

        for (uint i = 0; i < _agents.length; i++) {
            agents[_agents[i]] = true;
        }
    }

    function createHiroWallet()
        external
        payable
        override
        nonReentrant
        returns (address payable)
    {
        require(
            ownerToWallet[msg.sender] == address(0),
            "Subcontract already exists"
        );

        require(msg.value >= purchasePrice, "Insufficient funds");

        uint256 remaining = msg.value - purchasePrice;

        HiroWallet wallet = new HiroWallet{value: remaining}(msg.sender);

        ownerToWallet[msg.sender] = address(wallet);

        emit HiroCreated(msg.sender, address(wallet));

        return payable(wallet);
    }

    function sweep(address token, uint256 amount) external override onlyOwner {
        bool success = IERC20(token).transfer(msg.sender, amount);
        require(success, "Transfer failed");
    }

    function sweepETH() external override onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function setTransactionPrice(uint256 _price) external override onlyOwner {
        transactionPrice = _price;

        emit TransactionPriceSet(_price);
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
    }
}
