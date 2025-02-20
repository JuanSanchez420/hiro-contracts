// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IHiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "lib/slipstream/contracts/core/libraries/FullMath.sol";
import "lib/slipstream/contracts/core/CLPool.sol";


contract HiroWallet {
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

    event Executed(
        address indexed target,
        address indexed caller,
        bytes data,
        bytes result
    );

    constructor(
        address _owner,
        address _hiro,
        address _pool,
        address _weth
    ) payable {
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

    receive() external payable onlyOwner {}

    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    function getTokenPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , ) = ICLPool(pool).slot0();

        // Convert the Q64.96 sqrt price to a regular uint256 price.
        // The formula is: price = (sqrtPriceX96^2) / 2^192
        uint256 price = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 192);

        // TODO: looks wrong
        return weth < hiro ? 1 / price : price;
    }

    // Agent functions
    function execute(
        address target,
        bytes calldata data
    ) external onlyAgent onlyWhitelisted(target) returns (bytes memory) {
        uint256 gasStart = gasleft();

        (bool success, bytes memory result) = target.call(data);
        require(success, "Call failed");

        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;

        // Calculate requiredTokens using feeBasisPoints in basis points.
        // Dividing by 10000 converts basis points to a multiplier.
        uint256 feeBasisPoints = IHiroFactory(factory).purchasePrice();
        uint256 requiredTokens = (gasCost * feeBasisPoints) /
            (10000 * getTokenPrice());

        require(
            IERC20(hiro).balanceOf(address(this)) >= requiredTokens,
            "Insufficient tokens to cover fees"
        );

        IERC20(hiro).transfer(address(factory), requiredTokens);

        emit Executed(target, msg.sender, data, result);
        return result;
    }
}
