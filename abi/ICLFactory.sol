// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

interface ICLFactory {
    event DefaultUnstakedFeeChanged(uint24 indexed oldUnstakedFee, uint24 indexed newUnstakedFee);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PoolCreated(address indexed token0, address indexed token1, int24 indexed tickSpacing, address pool);
    event SwapFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);
    event SwapFeeModuleChanged(address indexed oldFeeModule, address indexed newFeeModule);
    event TickSpacingEnabled(int24 indexed tickSpacing, uint24 indexed fee);
    event UnstakedFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);
    event UnstakedFeeModuleChanged(address indexed oldFeeModule, address indexed newFeeModule);

    function allPools(uint256) external view returns (address);
    function allPoolsLength() external view returns (uint256);
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);
    function defaultUnstakedFee() external view returns (uint24);
    function enableTickSpacing(int24 tickSpacing, uint24 fee) external;
    function factoryRegistry() external view returns (address);
    function getPool(address, address, int24) external view returns (address);
    function getSwapFee(address pool) external view returns (uint24);
    function getUnstakedFee(address pool) external view returns (uint24);
    function isPool(address pool) external view returns (bool);
    function owner() external view returns (address);
    function poolImplementation() external view returns (address);
    function setDefaultUnstakedFee(uint24 _defaultUnstakedFee) external;
    function setOwner(address _owner) external;
    function setSwapFeeManager(address _swapFeeManager) external;
    function setSwapFeeModule(address _swapFeeModule) external;
    function setUnstakedFeeManager(address _unstakedFeeManager) external;
    function setUnstakedFeeModule(address _unstakedFeeModule) external;
    function swapFeeManager() external view returns (address);
    function swapFeeModule() external view returns (address);
    function tickSpacingToFee(int24) external view returns (uint24);
    function tickSpacings() external view returns (int24[] memory);
    function unstakedFeeManager() external view returns (address);
    function unstakedFeeModule() external view returns (address);
    function voter() external view returns (address);
}
