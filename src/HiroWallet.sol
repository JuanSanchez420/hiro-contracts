// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "lib/slipstream/contracts/core/libraries/FullMath.sol";
import "lib/slipstream/contracts/core/CLPool.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract HiroWallet is ReentrancyGuard {
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

    modifier onlyWhitelisted(address target) {
        require(
            IHiroFactory(factory).isWhitelisted(target),
            "Address not whitelisted"
        );
        _;
    }

    modifier onlyWhitelistedBatch(address[] calldata targets) {
        for (uint256 i = 0; i < targets.length; i++) {
            require(
                IHiroFactory(factory).isWhitelisted(targets[i]),
                "Address not whitelisted"
            );
        }
        _;
    }

    event Executed(address indexed target, address indexed caller, uint256 fee);

    constructor(address _owner) payable nonReentrant() {
        owner = _owner;
        factory = msg.sender;
    }

    receive() external payable {}

    // Owner functions
    function withdraw(address token, uint256 amount) external onlyOwner {
        bool success = IERC20(token).transfer(msg.sender, amount);
        require(success, "Transfer failed");
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    // Agent functions
    function execute(
        address target,
        bytes calldata data,
        uint256 ethAmount
    )
        external
        onlyAgent
        onlyWhitelisted(target)
        nonReentrant
        returns (uint256)
    {
        require(
            ethAmount <= address(this).balance,
            "Not enough ETH on hiro wallet"
        );

        uint256 gasStart = gasleft();
        (bool success, ) = payable(target).call{value: ethAmount}(data);
        require(success, "Call failed");

        uint256 feeBasisPoints = IHiroFactory(factory).transactionPrice();
        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        uint256 fee = (gasCost * feeBasisPoints) / 10000;

        require(address(this).balance >= fee, "Insufficient ETH to cover fees");
        (bool succeeded, ) = factory.call{value: fee}("");
        require(succeeded, "factory not paid");

        emit Executed(target, msg.sender, fee);
        return fee;
    }

    function batchExecute(
        address[] calldata targets,
        bytes[] calldata dataArray,
        uint256[] calldata ethAmounts
    )
        external
        onlyAgent
        onlyWhitelistedBatch(targets)
        nonReentrant
        returns (uint256 totalFee)
    {
        // Ensure all arrays have the same length
        require(
            targets.length == dataArray.length &&
                targets.length == ethAmounts.length,
            "Array length mismatch"
        );

        // Calculate total ETH needed for transactions
        uint256 totalEthAmount = 0;
        for (uint256 i = 0; i < ethAmounts.length; i++) {
            totalEthAmount += ethAmounts[i];
        }

        require(
            totalEthAmount <= address(this).balance,
            "Not enough ETH on wallet"
        );

        uint256 gasStart = gasleft();

        // Execute each transaction
        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, ) = payable(targets[i]).call{value: ethAmounts[i]}(
                dataArray[i]
            );
            require(success, "Call failed");

            emit Executed(targets[i], msg.sender, 0); // Fee will be calculated later
        }

        // Calculate fee based on total gas used
        uint256 feeBasisPoints = IHiroFactory(factory).transactionPrice();
        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        totalFee = (gasCost * feeBasisPoints) / 10000;

        require(address(this).balance >= totalFee, "Insufficient ETH for fees");

        (bool feeSuccess, ) = factory.call{value: totalFee}("");
        require(feeSuccess, "Factory fee payment failed");

        return totalFee;
    }
}
