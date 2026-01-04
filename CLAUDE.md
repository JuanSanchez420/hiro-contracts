# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test --match-test testName  # Run a specific test
forge test -vvv      # Run tests with verbose output
forge fmt            # Format Solidity code
forge snapshot       # Generate gas snapshots
```

## Deployment

The deployment script reads from `whitelist.json` for initial whitelisted addresses and environment variables for agents (`AGENT_ADDRESS_1`, `AGENT_ADDRESS_2`, etc. up to 5). Required env vars: `WETH`, `UNISWAP_SWAP_ROUTER`.

```bash
forge script script/Deploy.s.sol --rpc-url <rpc_url> --broadcast
```

## Architecture

This is a Foundry-based Solidity project using **Solidity 0.7.6** with two core contracts:

### HiroFactory (`src/HiroFactory.sol`)
- Factory contract that deploys and tracks HiroWallet instances (one per user)
- Maintains a whitelist of addresses that wallets are allowed to call
- Maintains a list of authorized agents who can execute transactions on wallets
- Owner can sweep tokens/ETH accidentally sent to the factory

### HiroWallet (`src/HiroWallet.sol`)
- Personal wallet contract created by HiroFactory for each user
- **Owner**: Can withdraw tokens and ETH
- **Agents**: Can execute batched calls to whitelisted addresses via `execute(targets[], data[], ethAmounts[])`
- All external calls are restricted to factory-whitelisted addresses

### Key Dependencies
- OpenZeppelin Contracts (0.7.x compatible)
- Uniswap V3 Core and Periphery (for whitelisted DeFi interactions)
- forge-std for testing
