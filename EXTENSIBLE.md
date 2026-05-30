# Hiro Strategy Module System

## Context

After the recent security-model rework, HiroWallet requires user-signed EIP-712 messages (`executeWithOwnerSig`) or direct owner calls to move funds. This prevents mass drains if agent keys are compromised, but breaks autonomous flows that need runtime parameters — most importantly Uniswap V3 LP rebalancing, where tick range and swap sizing depend on live market state.

Two more constraints shape this design:

1. **HiroWallets are immutable per-user bytecode** (CREATE2 with wallet creation code baked in). Adding new verbs directly to the wallet would force migrations or upgrade machinery. Neither is acceptable for a product where the wallet address is the user's identity.
2. **The existing API liquidity skill** (`hiro-api/.../rebalanceExecutor.ts`) orchestrates a multi-step rebalance from the agent process. That logic — call sequencing, slippage/impact bounds, protocol-fee split — is security-critical but lives in TypeScript outside any on-chain trust boundary.

This document defines a **strategy module system**: small Solidity contracts deployed once and factory-whitelisted, callable through a generic `executeStrategy` entry on the wallet. New skills become new strategies; deployed wallets get them for free. The agent gains back limited authority (factory `isAgent` whitelist) but only to *trigger* strategies whose call sequences are bounded by on-chain logic, not to execute arbitrary calldata.

Intended outcome: rebalance + auto-compound move on-chain with strong safety guarantees (every call still passes the factory `targetWhitelist`), the system extends to future protocols (Aave, additional DEXes) without touching wallets, and the agent's blast radius on compromise drops to "force-trigger whitelisted strategies."

## Architecture

**Execution model: plan-and-execute.**

```
agent (whitelisted) ──> wallet.executeStrategy(strategy, params)
                              │
                              ├─ require: factory.isAgent(msg.sender)
                              ├─ require: factory.isStrategy(strategy)
                              │
                              ├─ Call[] calls = strategy.plan(wallet, params)   // view
                              │
                              └─ _execute(calls)  // each call validated by factory.targetWhitelist
```

- `IStrategy.plan` is a **view function** that returns a `Call[]` given the wallet address and ABI-encoded params. It cannot mutate state. It cannot hold funds.
- The wallet executes returned calls through the existing `_execute` path, which calls `factory.validateCall(target)` per call. **All current safety properties of the wallet are preserved.**
- Strategy whitelist is admin-controlled on the factory, same trust level as `targetWhitelist`. Each strategy is small, focused, and independently auditable.
- Agent whitelist replaces the trust the old design placed in agent EOAs, but with no signing/calldata authority — agents can only invoke whitelisted strategies with whitelisted params.

**Per-strategy guardrails** (encoded in each strategy contract):
- Position ownership check (position NFT owner == wallet)
- Hard caps on user-tunable params (e.g., max width, max slippage bps, max impact bps)
- Min-amount checks baked into the returned calls (decreaseLiquidity, mint, swap)

**No on-chain rate limit (deliberate).** Earlier drafts added a per-position
`lastExecAt` throttle (`MIN_REBALANCE_INTERVAL` / `MIN_COMPOUND_INTERVAL`) to the
wallet. It was removed. On the deep pools Hiro operates on, a compromised agent
cannot *profitably* drain via `executeStrategy`: the per-call caps (slippage,
impact), the hardcoded `recipient` (wallet/factory), and the factory
`targetWhitelist` already bound the path to "burn to fees/impact, captured by no
one." There is no profitable swap to sandwich — a re-centered position targets
~50/50, so the forced swap is small or absent, and on a deep pool even a
half-position swap barely moves price; capturing that move would still cost
round-trip pool fees + gas + an ordering bribe (and Base has no open builder
market). Gross capture ≈ 0 minus those costs is negative. So the path is
grief-not-gain, and the throttle was never the control standing between
agent-key compromise and drain — the factory `pause` + out-of-band monitoring is.
Anti-thrash (an honest oscillating signal churning the 10% protocol fee), if ever
wanted, belongs **off-chain in the agent/API** where it is tunable and free, not
baked into immutable wallet bytecode (where a failed rebalance must not be allowed
to consume the interval). Revisit an on-chain throttle only if a strategy is ever
pointed at a shallow / low-float pool, where price impact becomes genuinely
extractable.

**Opt-in**: implicit via pre-approvals. Positions created through Hiro have approvals to NPM and SwapRouter pre-set during the user-signed mint flow. Strategies operate on positions where those approvals exist; positions without them simply fail their swap/mint calls.

## Phase 1 — Infrastructure (Factory + Wallet + IStrategy)

**Goal:** add the strategy/agent whitelist and `executeStrategy` entry without changing rebalance behavior. End of phase: a no-op test strategy can be deployed, whitelisted, and invoked.

Critical files:

- `src/interfaces/IHiroFactory.sol` — add `isAgent(address)`, `isStrategy(address)`, `addAgent/removeAgent`, `addStrategy/removeStrategy`, getters
- `src/HiroFactory.sol` — add `agentWhitelist` and `strategyWhitelist` mappings + owner-gated add/remove + events; reuse the existing `targetWhitelist` admin pattern at `HiroFactory.sol:87-99`
- `src/interfaces/IStrategy.sol` (new) — single `plan(address wallet, bytes calldata params) external view returns (HiroWallet.Call[] memory)`; pull `Call` into a shared `IHiroWallet.sol` interface so the strategy doesn't depend on the wallet implementation
- `src/HiroWallet.sol` — add `executeStrategy(IStrategy strategy, bytes calldata params) external nonReentrant`; refactor `_execute` to also accept `Call[] memory` (split current calldata variant into a thin wrapper)
- `test/HiroFactory.t.sol`, `test/HiroWallet.t.sol` — extend with agent/strategy whitelist tests and `executeStrategy` happy/sad path against a `NoopStrategy` mock

Sanity contracts in the wallet:
- `executeStrategy` reverts if `factory.paused()` (existing pause covers it via `validateCall` per call, but a top-level check fails fast)
- `_execute(Call[] memory)` and `_execute(Call[] calldata)` share an internal `_validateAndDispatch` helper

**Phase 1 build & test:**
1. `forge build`
2. `forge test` — all 88 existing tests pass + new tests for agent/strategy whitelist and `executeStrategy` with `NoopStrategy`
3. `make fork` + local deploy + cast call to add a noop strategy + invoke it via an agent EOA — confirm event emission and revert paths

## Phase 2 — UniV3 Rebalance Strategy

**Goal:** replicate today's `rebalanceExecutor.ts` flow as a strategy contract. Agent passes `(positionId, newTickLower, newTickUpper, slippageBps, maxImpactBps)`. The strategy reads on-chain state, computes expected amounts, returns the Call[] sequence.

Critical files:
- `src/strategies/UniV3RebalanceStrategy.sol` (new) — implements `IStrategy`
- `src/libraries/V3MathLib.sol` (new, if needed) — wraps `LiquidityAmounts` from `lib/v3-periphery` and the `TickMath` already vendored at `src/libraries/TickMath.sol`
- `test/strategies/UniV3RebalanceStrategy.t.sol` (new) — fork test against Base WETH/USDC pool
- Constants (NPM, SwapRouter02, V3Factory, WETH) from `hiro-api/.../constants.ts:NONFUNGIBLE_POSITION_MANAGER` (0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1 on Base 8453)

Strategy `plan()` builds, in order:

1. `NPM.decreaseLiquidity(positionId, liquidity=100%, amount0Min, amount1Min, deadline)` — `amount0Min`/`amount1Min` computed from `LiquidityAmounts.getAmountsForLiquidity(slot0, tickLower, tickUpper, liquidity)` × `(10000 - slippageBps) / 10000`
2. `NPM.collect(positionId, recipient=factory, amount0Max=protocolFee0, amount1Max=protocolFee1)` — 10% of fee portion routed to HiroFactory, matches current `rebalanceExecutor.ts` protocol-fee logic
3. `NPM.collect(positionId, recipient=wallet, amount0Max=MAX, amount1Max=MAX)` — remainder + principal
4. `NPM.burn(positionId)`
5. `SwapRouter02.exactInputSingle(...)` — sized via internal `_planOptimalSwap` so post-swap balances match the new range's expected ratio at current tick; reverts if quoted impact > `maxImpactBps`
6. `NPM.mint({token0, token1, fee, tickLower=newTickLower, tickUpper=newTickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min, recipient=wallet, deadline})`

Hard-coded sanity caps in the strategy:
- `slippageBps <= 100` (1%)
- `maxImpactBps <= 300` (3%)
- `newTickUpper - newTickLower >= MIN_WIDTH_TICKS` and `<= MAX_WIDTH_TICKS`
- `newTickLower < currentTick < newTickUpper` (new range must contain spot)

(No on-chain rate limit — see "No on-chain rate limit (deliberate)" in Architecture.)

Pool/router lookup: strategy holds immutable refs to NPM and SwapRouter02; the position's `fee` is read from `NPM.positions(positionId)`, pool address derived via `V3Factory.getPool(token0, token1, fee)`.

**Phase 2 build & test:**
1. `forge build`
2. `forge test --match-contract UniV3RebalanceStrategyTest -vvv`
3. **Fork test** (`make fork`): deploy factory + wallet + strategy, fund with WETH/USDC, mint a V3 position, call `executeStrategy` with a new range, assert: NFT burned, new NFT minted with new range, protocol fee landed at factory, slippage and impact bounds enforced (negative test with too-tight slippage reverts as expected)
4. Cross-check: total wallet value (oracle) before vs after stays within `slippageBps + maxImpactBps + fee`

## Phase 3 — UniV3 AutoCompound Strategy

**Goal:** collect fees on an existing position, swap to its current ratio, and re-deposit via `increaseLiquidity` — same range, same NFT. Agent passes `(positionId, slippageBps, maxImpactBps)`.

Critical files:
- `src/strategies/UniV3AutoCompoundStrategy.sol` (new) — implements `IStrategy`
- Reuses `V3MathLib` from Phase 2
- `test/strategies/UniV3AutoCompoundStrategy.t.sol` (new)

Strategy `plan()` builds:

1. `NPM.collect(positionId, recipient=factory, ...)` — 10% of fees to HiroFactory (preserves existing protocol-fee economics)
2. `NPM.collect(positionId, recipient=wallet, ...)` — 90% remainder
3. **On-chain sanity floor**: revert in `plan()` if the wallet-bound 90% portion (computed via fee-growth math from `IUniswapV3Pool` tick states + `positions().feeGrowthInside*LastX128`) is below `MIN_COMPOUND_NOTIONAL` (denominated against the position's token0/token1 — e.g., $5 worth using the position's spot tick). This is the "agent-decided with on-chain sanity floor" model.
4. `SwapRouter02.exactInputSingle(...)` — balance the two-sided amount for the position's existing range at current tick
5. `NPM.increaseLiquidity(positionId, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline)` — `amount0Min/1Min` via slippage bps

Hard caps mirror Phase 2 (`slippageBps <= 100`, `maxImpactBps <= 300`). No on-chain rate limit — see "No on-chain rate limit (deliberate)" in Architecture.

**Phase 3 build & test:**
1. `forge build`
2. `forge test --match-contract UniV3AutoCompoundStrategyTest -vvv`
3. **Fork test**: mint a position on the fork, simulate fee accrual by routing swaps through the pool (use vm.deal + impersonation of a large LP), call `executeStrategy(autoCompound, ...)`, assert: same NFT, increased liquidity, protocol-fee 10% at factory, sanity-floor revert when fees too small
4. Confirm `MIN_COMPOUND_NOTIONAL` triggers correctly using oracle/spot at runtime

## Phase 4 — Deployment Scripts + Production Deploy

Critical files:
- `script/DeployStrategies.s.sol` (new) — deploys `UniV3RebalanceStrategy` and `UniV3AutoCompoundStrategy` with the right NPM/SwapRouter/V3Factory addresses; emits whitelisting calls (or just logs the address for an owner-side tx)
- `makefile` — add `deploy-strategies` (local fork) and `deploy-strategies-base` (production, with `--verify --account deployer`); follow the existing `deploy-base`/`deploy-season` patterns
- One-time mainnet upgrade flow: owner calls `addStrategy(rebalance)`, `addStrategy(autoCompound)`, `addAgent(<each agent EOA>)` on the existing factory after Phase 1 ship

Targets to add to `whitelist.json` if not already present (verify during Phase 1):
- `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1` (NPM)
- `0x2626664c2603336E57B271c5C0b26F421741e481` (SwapRouter02)
- Underlying tokens for all currently-tracked positions

**Phase 4 verify:**
1. `make fork && make deploy && make deploy-strategies` — deploys factory + strategies locally; cast calls to whitelist them; run a full rebalance + compound against the fork
2. Dry-run `forge script DeployStrategies --rpc-url base --fork-url $BASE_RPC` to confirm artifact paths and verification metadata
3. Production deploy is a separate, gated step — not part of this plan

## Phase 5 — API Integration

**Goal:** replace the API's call-orchestration logic with a single `executeStrategy` invocation per skill. The off-chain Donchian/range-recommendation code stays — it just produces the params now instead of orchestrating calls.

Critical files (in `hiro-api/`):
- `src/skills/liquidity/tools/rebalance.ts` — replace `rebalanceExecutor.ts` call-construction with a single `executeStrategy(REBALANCE_STRATEGY_ADDR, abi.encode(positionId, newTickLower, newTickUpper, slippageBps, maxImpactBps))` call submitted by an agent EOA
- `src/skills/liquidity/tools/autoCompound.ts` (new) — equivalent for compound
- `src/skills/liquidity/lpMonitor.ts` (job) — keep the trigger logic, just point it at the new tool
- `src/skills/liquidity/constants.ts` — add `REBALANCE_STRATEGY_ADDR`, `AUTO_COMPOUND_STRATEGY_ADDR`
- `src/agents/prompts/tools/liquidity.md` — update tool descriptions; add auto-compound

**Phase 5 verify:**
1. Local: API points at the forked factory + strategies, agent end-to-end rebalances a tracked position through the new path
2. Local: agent runs auto-compound; confirms tracked position liquidity grew, protocol fee landed
3. The old `rebalanceExecutor.ts` orchestration can be removed once parity is confirmed

## Verification Summary

Each phase must pass before the next starts:

| Phase | Build | Unit tests | Fork test |
|---|---|---|---|
| 1 | `forge build` | `forge test` (88 existing + new) | Whitelist + noop `executeStrategy` |
| 2 | `forge build` | rebalance unit tests | Full rebalance on Base fork, WETH/USDC, with negative slippage/impact cases |
| 3 | `forge build` | compound unit tests | Compound with simulated fee accrual; sanity-floor revert |
| 4 | `forge build` | scripts compile | `make deploy && make deploy-strategies` round-trip on fork |
| 5 | `npm run build` (api) | api unit tests | End-to-end rebalance + compound from API → fork |

Final acceptance: a tracked position on a forked Base mainnet can be (a) rebalanced and (b) auto-compounded purely through the new strategy path, with protocol fees landing at the factory and all old test cases still green.

## Out of scope (explicit)

- Wallet upgradeability (deliberately avoided; that's what strategies replace)
- Volatility/Donchian range computation on-chain (stays in API for now; passed in as params)
- New protocol integrations (Aave skill) — the architecture supports them but they're follow-on strategies, not this plan
- Session keys / EIP-712 permit infrastructure — explicitly rejected in favor of strategy-shaped authority
