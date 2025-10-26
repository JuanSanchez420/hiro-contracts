# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Core Development
```bash
# Build contracts
forge build

# Run all tests
forge test

# Run specific test file
forge test --match-path test/HiroWallet.t.sol

# Run specific test function
forge test --match-test testExecute

# Run tests with verbosity (-v to -vvvvv for increasing detail)
forge test -vvv

# Format code
forge fmt

# Generate gas snapshots
forge snapshot
```

### Local Development Environment
```bash
# Start local fork of Base chain (uses Anvil)
make fork

# Deploy contracts to local chain
make deploy

# Approve factory contract (approves factory to spend WETH)
make approve-factory

# Create a new wallet
make create-wallet
```

### Environment Variables Required
Create a `.env` file in the project root with:
- `WETH`: WETH token address on Base
- `UNISWAP_SWAP_ROUTER`: Uniswap V3 swap router address
- `UNISWAP_NONFUNGIBLEPOSITIONMANAGER`: Uniswap V3 position manager address
- `UNISWAP_FACTORY`: Uniswap V3 factory address
- `UNISWAP_QUOTER`: Uniswap V3 quoter address
- `AAVE_POOL`, `AAVE_POOL_ADDRESS_PROVIDER`, etc.: Aave protocol addresses
- `MULTICALL`: Multicall3 contract address
- `AGENT_ADDRESS_1`, `AGENT_ADDRESS_2`, etc.: Agent addresses authorized to execute transactions

## Project Architecture

### Core Contracts
- **HiroFactory** (`src/HiroFactory.sol`): Minimal factory that deploys `HiroWallet` instances
  - Collects the flat 0.01 ETH purchase fee (`purchasePrice`) and forwards any extra ETH to the wallet
  - Maintains the whitelist of callable contracts and an agent registry shared across all wallets
  - Enforces one wallet per EOAs via the `ownerToWallet` mapping
  - Owner can sweep stray ERC20s or ETH from the factory

- **HiroWallet** (`src/HiroWallet.sol`): Simple agent-operated wallet
  - Constructed by the factory with immutable `owner` and `factory` addresses
  - Exposes a single `execute(address[] targets, bytes[] data, uint256[] values)` entry point
    - Validates array lengths, ensures each target is whitelisted by the factory, and requires sufficient ETH
    - Iterates through the call bundle, forwarding calldata and optional ETH per target
  - Owner can withdraw arbitrary ERC20 tokens or raw ETH that accumulate in the wallet

### Key Features & Architecture Details

**Economic Model**
- The only enforced payment is the 0.01 ETH wallet purchase fee.
- Bundled executions do **not** skim tokens or charge gas-percentage fees—agents simply consume wallet balances.

**Security & Access Control**
- **Whitelist**: The factory centrally manages allowed targets; wallets consult it before every call.
- **Agents**: Factory-approved addresses can submit `execute` bundles across any wallet. Owners are the only parties who can withdraw funds.
- **Reentrancy**: Both the factory and wallet inherit OpenZeppelin `ReentrancyGuard`.

### Dependencies & Tooling
- **Solidity**: Version 0.7.6 with ABIEncoderV2 enabled
- **OpenZeppelin**: Ownable + ReentrancyGuard contracts are the only on-chain dependencies right now
- **Foundry**: Build system, testing framework, deployment tooling
- **Vendored Deps**: The repo still vendors Uniswap/Aave sources for future work, but they are not referenced by the simplified contracts.

### Test Structure
- `test/HiroFactory.t.sol`: Covers wallet creation, whitelist + agent management, purchase price enforcement, and owner sweep functionality.
- `test/HiroWallet.t.sol`: Focuses on the bundled `execute` call (success, whitelist enforcement, array validation, ETH accounting) plus owner withdrawals.
- Tests run against the default Anvil instance; no fork or environment variables are required for the current unit suites.
- The deploy script (`script/Deploy.s.sol`) still reads whitelist/agent data from files + env vars to stay compatible with future network workflows.

### Configuration Files
- `foundry.toml`: Solidity compiler settings, enables reading `whitelist.json` via fs_permissions
- `whitelist.json`: Production whitelist of contract addresses (DEX routers, tokens, etc.)
- `makefile`: Shortcuts for common development tasks (fork, deploy, create wallet)
- `.env`: Environment variables for deployment (network addresses, agent addresses)
