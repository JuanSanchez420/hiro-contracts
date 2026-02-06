# CLAUDE.md

Foundry-based Solidity project using **Solidity 0.7.6** on Base L2.

## Commands

```bash
forge build                          # Compile
forge test                           # Run all tests (88 tests)
forge test --match-test testName     # Run specific test
forge test -vvv                      # Verbose output
forge fmt                            # Format code
```

## Contracts

### HiroFactory + HiroWallet (Core)
Smart wallet system where AI agents execute DeFi transactions safely:
- **HiroFactory**: Deploys one HiroWallet per user, manages whitelist and agents
- **HiroWallet**: Owner withdraws funds, agents execute batched calls to whitelisted addresses only

### HiroSeason + HiroToken (Seasonal)
30-day token seasons with guaranteed redemption:
1. **SETUP**: Fund redemption pool, create Uniswap V3 pool with single-sided HIRO liquidity
2. **ACTIVE**: Users trade, owner can buyback HIRO with fees
3. **ENDED**: Season ends after 30 days
4. **REDEEMABLE**: LP withdrawn, contract HIRO burned, holders redeem for pro-rata ETH

Non-ruggable: Owner cannot extract ETH, HIRO, or LP NFT.

## Deployment

```bash
forge script script/Deploy.s.sol --rpc-url <rpc_url> --broadcast
```

Requires `whitelist.json` and env vars: `WETH`, `UNISWAP_SWAP_ROUTER`, `AGENT_ADDRESS_1` through `AGENT_ADDRESS_5`.
