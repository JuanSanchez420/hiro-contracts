// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IHiroFactory.sol";

contract HiroWallet {
    address public owner;
    address public factory;
    address public immutable tokenAddress;
    address public immutable agentAddress;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyAgent() {
        require(msg.sender == agentAddress, "Not the agent");
        _;
    }

    modifier onlyWhitelisted(address target) {
        require(
            IHiroFactory(factory).isWhitelisted(target),
            "Address not whitelisted"
        );
        _;
    }

    event Executed(address indexed target, address indexed caller, bytes data, bytes result);

    constructor(
        address _owner,
        address _tokenAddress,
        address _agentAddress
    ) payable {
        owner = _owner;
        tokenAddress = _tokenAddress;
        agentAddress = _agentAddress;
        factory = msg.sender;


    }

    // Owner functions
    function deposit(uint256 amount) external payable onlyOwner {
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
    }

    receive() external payable onlyOwner {}

    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    // Agent functions
    function execute(
        address target,
        bytes calldata data
    ) external onlyAgent onlyWhitelisted(target) returns (bytes memory) {
        (bool success, bytes memory result) = target.call(data);
        require(success, "Call failed");

        emit Executed(target, msg.sender, data, result);
        return result;
    }
}
