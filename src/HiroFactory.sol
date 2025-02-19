// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./HiroWallet.sol";
import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract HiroFactory is Ownable, IHiroFactory {
    event HiroCreated(address indexed owner, address indexed wallet);
    event PriceSet(uint256 price);
    event Whitelisted(address indexed addr);
    event RemovedFromWhitelist(address indexed addr);

    mapping(address => address) public override ownerToWallet;
    address public immutable tokenAddress;
    mapping(address => bool) private whitelist;
    mapping(address => bool) private agents;

    uint256 public override price;

    constructor(
        address _tokenAddress,
        uint256 _price,
        address factoryOwner,
        address[] memory _whitelist,
        address[] memory _agents
    ) {
        tokenAddress = _tokenAddress;
        price = _price;
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
        returns (address payable)
    {
        require(
            ownerToWallet[msg.sender] == address(0),
            "Subcontract already exists"
        );

        IERC20(tokenAddress).transferFrom(msg.sender, address(this), price);

        HiroWallet wallet = new HiroWallet{value: msg.value}(
            msg.sender,
            tokenAddress
        );

        ownerToWallet[msg.sender] = address(wallet);

        emit HiroCreated(msg.sender, address(wallet));

        return payable(wallet);
    }

    function sweep(address token, uint256 amount) external override onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }

    function sweepETH() external override onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function setPrice(uint256 _price) external override onlyOwner {
        price = _price;

        emit PriceSet(_price);
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
