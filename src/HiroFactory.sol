// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HiroWallet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IHiroFactory.sol";

contract HiroFactory is Ownable(msg.sender), IHiroFactory {

    event HiroCreated(address indexed owner, address indexed wallet);
    event PriceSet(uint256 price);
    event Whitelisted(address indexed addr);
    event RemovedFromWhitelist(address indexed addr);

    mapping(address => address) public override ownerToWallet;
    address public immutable tokenAddress;
    address public immutable agentAddress;
    mapping(address=>bool) private whitelist;

    uint256 public override price;

    constructor(address _tokenAddress, address _agentAddress, uint256 _price, address[] memory _whitelist) {
        tokenAddress = _tokenAddress;
        agentAddress = _agentAddress;
        price = _price;

        for(uint i = 0; i < _whitelist.length; i++) {
            whitelist[_whitelist[i]] = true;
        }
    }

    function createHiroWallet(uint256 tokenAmount) external override payable {
        require(ownerToWallet[msg.sender] == address(0), "Subcontract already exists");
        require(tokenAmount >= price, "Token amount must be greater than price");

        IERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);

        HiroWallet wallet = new HiroWallet{value: msg.value}(msg.sender, tokenAddress, agentAddress);

        ownerToWallet[msg.sender] = address(wallet);
    }

    function sweep(address token, uint256 amount) external override onlyOwner() {
        IERC20(token).transfer(msg.sender, amount);
    }

    function sweepETH() external override onlyOwner() {
        payable(msg.sender).transfer(address(this).balance);
    }

    function setPrice(uint256 _price) external override onlyOwner() {
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

    function isWhitelisted(address addr) external override view returns (bool) {
        return whitelist[addr];
    }

    function getWallet(address owner) external override view returns (address) {
        return ownerToWallet[owner];
    }
}