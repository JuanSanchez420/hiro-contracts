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
        factory.call{value: fee}("");

        emit Executed(target, msg.sender, fee);
        return fee;
    }
}
