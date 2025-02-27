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
    address public immutable hiro;
    address public immutable pool;
    address public immutable weth;

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

    constructor(
        address _owner,
        address _hiro,
        address _pool,
        address _weth
    ) payable nonReentrant() {
        owner = _owner;
        hiro = _hiro;
        pool = _pool;
        weth = _weth;
        factory = msg.sender;
    }

    // Owner functions
    function deposit(address token, uint256 amount) external onlyOwner {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    receive() external payable onlyOwner nonReentrant() {}

    function withdraw(address token, uint256 amount) external onlyOwner {
        bool success = IERC20(token).transfer(msg.sender, amount);
        require(success, "Transfer failed");
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    // returns ETH priced in Hiro tokens
    function getTokenPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , ) = ICLPool(pool).slot0();

        // Convert Q64.96 to regular price
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        require(price > 0, "Invalid token price");

        return weth < hiro ? price : 1 / price;
    }

    // Agent functions
    function execute(
        address target,
        bytes calldata data,
        uint256 ethAmount
    ) external onlyAgent onlyWhitelisted(target) returns (uint256) {
        require(ethAmount >= address(this).balance, "Incorrect ETH amount");

        uint256 gasStart = gasleft();

        (bool success, ) = payable(target).call{value: ethAmount}(data);
        require(success, "Call failed");

        uint256 feeBasisPoints = IHiroFactory(factory).transactionPrice();

        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        uint256 feeInEth = (gasCost * feeBasisPoints) / 10000;

        uint256 tokenPrice = getTokenPrice();

        uint256 requiredTokens = feeInEth * tokenPrice;

        require(
            IERC20(hiro).balanceOf(address(this)) >= requiredTokens,
            "Insufficient tokens to cover fees"
        );

        IERC20(hiro).transfer(address(factory), requiredTokens);

        return requiredTokens;
    }
}
