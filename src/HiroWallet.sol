// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/math/SafeMath.sol";

contract HiroWallet is ReentrancyGuard {
    using SafeMath for uint256;

    address public immutable owner;
    address public immutable factory;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyAgent() {
        require(IHiroFactory(factory).isAgent(msg.sender), "Not an agent");
        _;
    }

    event Executed(address indexed target, address indexed caller, uint256 value);

    constructor(address _owner) payable {
        owner = _owner;
        factory = msg.sender;
    }

    receive() external payable {}

    // Owner functions
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        bool success = IERC20(token).transfer(msg.sender, amount);
        require(success, "Transfer failed");
    }

    function withdrawETH(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= address(this).balance, "Insufficient ETH balance");
        (bool success, ) = payable(owner).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function execute(
        address[] calldata targets,
        bytes[] calldata dataArray,
        uint256[] calldata ethAmounts
    )
        external
        onlyAgent
        nonReentrant
    {
        uint256 length = targets.length;
        require(length > 0, "No calls provided");
        require(
            length == dataArray.length && length == ethAmounts.length,
            "Array length mismatch"
        );

        uint256 totalEth;
        for (uint256 i = 0; i < length; i++) {
            totalEth = totalEth.add(ethAmounts[i]);
        }
        require(totalEth <= address(this).balance, "Not enough ETH on wallet");

        for (uint256 i = 0; i < length; i++) {
            require(
                IHiroFactory(factory).isWhitelisted(targets[i]),
                "Address not whitelisted"
            );

            (bool success, ) = payable(targets[i]).call{value: ethAmounts[i]}(
                dataArray[i]
            );
            require(success, "Call failed");

            emit Executed(targets[i], msg.sender, ethAmounts[i]);
        }
    }
}
