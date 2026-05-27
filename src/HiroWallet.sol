// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

contract HiroWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error CallFailed();
    error InsufficientETH();
    error EthTransferFailed();
    error EmptyCalls();
    error LengthMismatch();

    address public immutable owner;
    address public immutable factory;

    event Executed(address indexed target, uint256 value);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) payable {
        owner = _owner;
        factory = msg.sender;
    }

    receive() external payable {}

    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner nonReentrant {
        if (amount > address(this).balance) revert InsufficientETH();
        (bool success,) = payable(owner).call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    function execute(address[] calldata targets, bytes[] calldata dataArray, uint256[] calldata ethAmounts)
        external
        onlyOwner
        nonReentrant
    {
        uint256 length = targets.length;
        if (length == 0) revert EmptyCalls();
        if (length != dataArray.length || length != ethAmounts.length) revert LengthMismatch();

        uint256 totalEth;
        for (uint256 i = 0; i < length; i++) {
            totalEth += ethAmounts[i];
        }
        if (totalEth > address(this).balance) revert InsufficientETH();

        for (uint256 i = 0; i < length; i++) {
            IHiroFactory(factory).validateCall(targets[i]);

            (bool success,) = payable(targets[i]).call{value: ethAmounts[i]}(dataArray[i]);
            if (!success) revert CallFailed();

            emit Executed(targets[i], ethAmounts[i]);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
