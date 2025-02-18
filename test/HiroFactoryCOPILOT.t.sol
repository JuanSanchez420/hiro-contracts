// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "./HiroFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "forge-std/Vm.sol";

contract HiroFactoryTest is DSTest {
    HiroFactory factory;
    IERC20 token;
    address owner = address(this);
    address agent = address(0x123);
    address user = address(0x456);
    uint256 initialPrice = 1000;
    uint256 tokenAmount = 2000;
    Vm vm = Vm(HEVM_ADDRESS);
    
    function setUp() public {
        token = new MockERC20();
        address[] memory whitelist = new address[](1);
        whitelist[0] = user;
        factory = new HiroFactory(address(token), agent, initialPrice, whitelist);
    }
    
    function testCreateHiroWallet() public {
        token.mint(user, tokenAmount);
        vm.prank(user);
        token.approve(address(factory), tokenAmount);
        vm.prank(user);
        factory.createHiroWallet(tokenAmount);
        assert(factory.ownerToWallet(user) != address(0));
    }

    function testFailCreateHiroWalletInsufficientAmount() public {
        vm.prank(user);
        factory.createHiroWallet(initialPrice - 1);
    }

    function testFailCreateHiroWalletAlreadyExists() public {
        token.mint(user, tokenAmount);
        vm.prank(user);
        token.approve(address(factory), tokenAmount);
        vm.prank(user);
        factory.createHiroWallet(tokenAmount);
        vm.prank(user);
        factory.createHiroWallet(tokenAmount);
    }

    function testSweep() public {
        token.mint(address(factory), tokenAmount);
        factory.sweep(address(token), tokenAmount);
        assert(token.balanceOf(owner) == tokenAmount);
    }

    function testFailSweepAsNonOwner() public {
        vm.prank(user);
        factory.sweep(address(token), tokenAmount);
    }

    function testSweepETH() public {
        payable(address(factory)).transfer(1 ether);
        factory.sweepETH();
        assert(owner.balance == 1 ether);
    }

    function testFailSweepETHAsNonOwner() public {
        vm.prank(user);
        factory.sweepETH();
    }

    function testSetPrice() public {
        uint256 newPrice = 2000;
        factory.setPrice(newPrice);
        assert(factory.price() == newPrice);
    }

    function testFailSetPriceAsNonOwner() public {
        uint256 newPrice = 2000;
        vm.prank(user);
        factory.setPrice(newPrice);
    }

    function testAddToWhitelist() public {
        address newAddress = address(0x789);
        factory.addToWhitelist(newAddress);
        assert(factory.isWhitelisted(newAddress));
    }

    function testFailAddToWhitelistZeroAddress() public {
        factory.addToWhitelist(address(0));
    }

    function testRemoveFromWhitelist() public {
        factory.removeFromWhitelist(user);
        assert(!factory.isWhitelisted(user));
    }

    function testFailRemoveFromWhitelistZeroAddress() public {
        factory.removeFromWhitelist(address(0));
    }

    function testIsWhitelisted() public {
        assert(factory.isWhitelisted(user));
    }

    function testGetWallet() public {
        token.mint(user, tokenAmount);
        vm.prank(user);
        token.approve(address(factory), tokenAmount);
        vm.prank(user);
        factory.createHiroWallet(tokenAmount);
        assert(factory.getWallet(user) != address(0));
    }
}

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        allowance[sender][msg.sender] -= amount;
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function mint(address account, uint256 amount) public {
        balanceOf[account] += amount;
        totalSupply += amount;
    }
}