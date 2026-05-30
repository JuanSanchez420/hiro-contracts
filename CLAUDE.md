# CLAUDE.md

Foundry-based Solidity project using **Solidity 0.8.20** (OpenZeppelin v4.9.6) on Base L2.

## Commands

```bash
forge build                          # Compile
forge test                           # Run all tests
forge test --match-test testName     # Run specific test
forge test -vvv                      # Verbose output
forge fmt                            # Format code
```

## Contracts

### HiroFactory + HiroWallet (Core)
Smart wallet system. Authority lives in the wallet **owner's signature**, not in
off-chain agent keys — a compromised key cannot drain wallets en masse.

- **HiroFactory**: Deploys one HiroWallet per user (CREATE2). Holds the mutable
  `targetWhitelist` of callable protocols, a global `paused` kill switch, and
  `validateCall(target)` that every wallet call routes through. Owner-gated
  (intended multisig); no timelock.
- **HiroWallet**: Owner withdraws funds. Execution is owner-authorized:
  - `executeWithOwnerSig(calls, nonce, deadline, sig)` — anyone may relay a bundle
    the owner signed via EIP-712 (OZ `SignatureChecker`, EOA + ERC-1271);
    Permit2-style bitmap nonces; `invalidateNonce` cancels.
  - `executeAsOwner(calls)` — owner submits directly from their EOA (liveness
    fallback when relayers are down).
  - Every call still passes `factory.validateCall` (pause + target whitelist).

The old global `agents` mapping and `execute(targets,data,eth)` surface are
**gone**. This intentionally breaks the API/frontend until they migrate to the
signed-bundle flow — remaining phases are tracked in `TX_SECURITY_ROADMAP.md`.

**Strategy module system:** to restore *bounded* autonomy for
agents (e.g. Uniswap V3 LP rebalancing whose params depend on live state), the
factory gains `agentWhitelist`/`strategyWhitelist` and the wallet a generic
`executeStrategy(strategy, params)` entry. A whitelisted agent triggers a
whitelisted strategy whose `plan()` (a view fn) returns the `Call[]`; every call
still passes `factory.validateCall`. Shipped strategies live in `src/strategies/`
(`UniV3RebalanceStrategy`, `UniV3AutoCompoundStrategy`).

**Per-wallet strategy opt-in (mass-drain firewall):** `executeStrategy` also
requires the wallet owner to have opted the strategy in via
`HiroWallet.setStrategy(strategy, true)` (`enabledStrategies` mapping) — the
factory `strategyWhitelist` is "globally permitted to exist", the per-wallet
opt-in is "I authorize this strategy against *my* funds". Both must hold. This
keeps the en-masse-drain invariant intact even against a **compromised factory
key**: such a key controls both global whitelists, but a strategy it registers
has zero per-wallet opt-ins, so it can move no user's funds. Opt-in is gasless —
the owner signs a bundle `[setStrategy(strat, true)]` relayed through
`executeWithOwnerSig`. The wallet's `_execute(calls, allowSelf)` permits a wallet
self-call (so the bundle reaches `setStrategy` without whitelisting the wallet)
**only** on owner-authorized paths; `executeStrategy` runs with `allowSelf=false`,
so a strategy's `plan()` can never target the wallet itself. Pause is still
enforced on self-calls.

### HiroSeason + HiroToken (Seasonal)
30-day token seasons with guaranteed redemption:
1. **SETUP**: Fund redemption pool, create Uniswap V3 pool with single-sided HIRO liquidity
2. **ACTIVE**: Users trade, owner can buyback HIRO with fees
3. **ENDED**: Season ends after 30 days
4. **REDEEMABLE**: LP withdrawn, contract HIRO burned, holders redeem for pro-rata ETH

Non-ruggable: Owner cannot extract ETH, HIRO, or LP NFT.

## Toolchain notes

- Solidity **0.8.20**, OpenZeppelin **v4.9.6**. Native overflow checks; no SafeMath.
- `src/libraries/TickMath.sol` is **vendored** (Uniswap V3's library is 0.7.x).
  Only `getSqrtRatioAtTick` needed an `unchecked` block (overflow-by-design).
  Parity with the original 0.7.6 output is locked by golden values in
  `test/fixtures/tickmath_golden.csv` (`test/TickMath.t.sol`) — if you touch
  TickMath or the compiler version, keep that test green.

## Deployment

The factory v2 constructor takes a single `address[] initialTargets` (the initial
`targetWhitelist`), sourced from `whitelist.json`. The old `AGENT_ADDRESS_1..5`
env vars are gone — agents and strategies are registered post-deploy by the owner
via `addAgent` / `addStrategy`.

### Local Development

```bash
make fork                            # Start Anvil with Base fork
make deploy                          # Deploy HiroFactory to Anvil (unlocked accounts)
```

### Production (Base Mainnet)

Import a deployer key first, then deploy. Requires `BASESCAN_API_KEY` env var for verification.

```bash
make import-key                      # Import key as "deployer" (default)
make import-key ACCOUNT=mykey        # Import key with custom name
make deploy-base                     # Deploy HiroFactory to Base
make deploy-season                   # Deploy HiroSeason to Base
```
