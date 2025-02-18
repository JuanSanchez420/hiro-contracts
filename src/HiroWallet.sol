// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";


contract HiroWallet {
    address public owner;
    address public factory;
    address public immutable tokenAddress;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyAgent() {
        require(IHiroFactory(factory).isAgent(msg.sender), "Not an agent");
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
        address _tokenAddress
    ) payable {
        owner = _owner;
        tokenAddress = _tokenAddress;
        factory = msg.sender;
    }

    // Owner functions
    function deposit(address token, uint256 amount) external onlyOwner {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
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
