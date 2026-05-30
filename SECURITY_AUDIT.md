# Security Audit

Date: 2026-05-30

Scope reviewed:

- `src/HiroWallet.sol`
- `src/HiroFactory.sol`
- `src/HiroSeason.sol`
- `src/HiroToken.sol`
- `src/strategies/UniV3RebalanceStrategy.sol`
- `src/strategies/UniV3AutoCompoundStrategy.sol`
- `src/libraries/*`
- Deployment scripts, whitelist, tests, and `TX_SECURITY_ROADMAP.md` for intended trust assumptions

This was a manual contract review with local build/unit-test verification. It is not a formal verification report.

## Executive Summary

The owner-signed wallet execution path is well structured: EIP-712 messages bind the wallet, owner, full call bundle, nonce, and deadline, and nonces are consumed atomically only after signature validation. The factory pause and target whitelist are consistently checked during wallet execution.

The largest issue is that `HiroWallet.executeStrategy` reintroduces a global, ownerless execution path. A whitelisted agent can trigger whitelisted strategies on any wallet without a wallet-owner signature, and a compromised factory admin can whitelist a malicious strategy/agent and drain whitelisted tokens from all wallets. This directly conflicts with the stated roadmap goal that no off-chain key can drain wallets at rest or en masse.

The seasonal token system has a separate high-risk economic issue: after the 3-day grace period, anyone can call `openRedemption(0)` and finalize redemption against the current Uniswap V3 spot composition. If the pool is manipulated at that moment, redemption can be crystallized at an unfavorable WETH amount.

## Findings

### C-01: Ownerless strategy execution enables global wallet compromise

Severity: Critical

Affected code:

- `src/HiroWallet.sol:96-103`
- `src/HiroWallet.sol:166-170`
- `src/HiroFactory.sol:77-80`
- `src/HiroFactory.sol:107-125`
- `whitelist.json`

`executeStrategy` authorizes execution with only factory-level `agentWhitelist` and `strategyWhitelist` checks. It does not require an owner signature, a per-wallet delegation, a per-position authorization, or a nonce/deadline from the wallet owner.

That creates two dangerous paths:

1. A compromised whitelisted agent can execute every whitelisted strategy against every Hiro wallet that owns a compatible position. Existing strategies are constrained, but they still move liquidity and perform swaps using agent-supplied params.
2. A compromised factory owner can add an attacker-controlled strategy and agent, then call `executeStrategy` on every wallet. The malicious strategy can return calls such as `ERC20.transfer(attacker, balance)` for any token already in `targetWhitelist`. `whitelist.json` includes WETH, USDC, and many token/protocol addresses, so `_execute` will accept those token calls. The call is made by the wallet itself, so the token transfer drains wallet balances without an owner signature.

This contradicts the explicit security objective in `TX_SECURITY_ROADMAP.md` that no agent, relayer, KMS, API, or factory-admin key can drain wallets at rest or en masse.

Recommended fix:

- Remove `executeStrategy`, or require an owner EIP-712 signature over `strategy`, `params`, wallet, nonce, and deadline before a strategy can execute.
- If unattended automation is required, make delegation per wallet and scoped by strategy, position id, token set, value limits, max loss/slippage, and expiry.
- Apply selector/argument policy to non-owner-signed execution. Target-only whitelisting is too coarse for ERC20 tokens because `approve`, `transfer`, and `transferFrom` share the same target address.
- Treat factory owner/admin keys as able to drain all wallets until this is fixed.

### H-01: Permissionless redemption can lock in a manipulated V3 spot composition

Severity: High

Affected code:

- `src/HiroSeason.sol:397-411`
- `src/HiroSeason.sol:414-430`
- `src/HiroSeason.sol:452-455`

`openRedemption` withdraws the entire V3 LP position and snapshots `totalRedemptionWETH` from the contract's WETH balance. During the owner-only grace window, the owner can pass a protective `minWethOut`. After `REDEMPTION_GRACE_PERIOD`, any caller can execute `openRedemption` and choose `minWethOut`, including `0`.

Because V3 LP withdrawal amounts depend on current pool price, an attacker can manipulate the HIRO/WETH spot composition near redemption, call `openRedemption(0)`, and permanently snapshot the resulting WETH balance. The contract then burns all HIRO it received from the LP and sets a fixed redemption rate. Honest holders cannot later recover from the manipulated finalization.

The 3-day owner grace period reduces operational risk if the owner always opens redemption promptly with a good minimum. It does not make the permissionless fallback safe.

Recommended fix:

- Store a protocol-level minimum WETH floor before/at season end and enforce it for all callers, including permissionless callers.
- Add a TWAP-vs-spot bound before `decreaseLiquidity`, or otherwise prevent finalization when spot is materially displaced.
- Consider making permissionless finalization two-step: anyone can request finalization after grace, but the withdrawal must satisfy a precommitted min-out or oracle/TWAP condition.
- Add fork tests that manipulate the pool immediately before `openRedemption` and assert redemption cannot be finalized below the intended WETH floor.

### L-01: Rebalance strategy undercharges protocol fees on unpoked accrued fees

Severity: Low

Affected code:

- `src/strategies/UniV3RebalanceStrategy.sol:95-97`
- `src/strategies/UniV3RebalanceStrategy.sol:140-144`
- `src/strategies/UniV3RebalanceStrategy.sol:215-243`

`UniV3RebalanceStrategy` calculates protocol fees only from `positions(positionId).tokensOwed0/1`. In Uniswap V3, fees accrued since the last poke are not necessarily reflected in `tokensOwed*`. The rebalance flow calls `decreaseLiquidity` first, which realizes accrued fees, but the protocol fee amounts were already computed from the stale `tokensOwed*` values.

As a result, a rebalance can send less than the intended 10% fee to `hiroFactory`, and in the zero-owed case it can skip the protocol-fee collect entirely while the subsequent wallet collect receives all newly realized fees. `UniV3AutoCompoundStrategy` already handles this correctly by reconstructing uncollected fees from fee-growth data.

Recommended fix:

- Use the same `V3MathLib.getUncollectedFees` fee-growth approach in `UniV3RebalanceStrategy`.
- Add a rebalance test where fees accrue without a poke, then assert the factory receives 10% of the full claimable fees.

### L-02: Plain ETH sent to `HiroSeason` is not protected as redemption funding

Severity: Low

Affected code:

- `src/HiroSeason.sol:140-145`
- `src/HiroSeason.sol:153-160`
- `src/HiroSeason.sol:358-364`
- `src/HiroSeason.sol:493-497`

`fundRedemption` wraps ETH and increments `redemptionPool`. The plain `receive()` path also wraps ETH, but it does not increment `redemptionPool`. WETH received directly or via plain ETH transfer is therefore treated as excess WETH and can be spent by `executeBuyback` while the season is active.

This may be intentional for fees/donations, but it is easy for a funder to send ETH to the contract address and mistakenly believe they protected redemption liquidity.

Recommended fix:

- Either revert plain ETH transfers except from WETH, or make `receive()` call the same accounting path as `fundRedemption` when the state allows funding.
- If direct donations are intentionally buyback-only, emit an event and document that plain transfers are not protected redemption funds.

## Notable Trust Assumptions

- Factory owner can pause execution, mutate target/agent/strategy whitelists, and sweep assets held by the factory.
- Wallet owners can always withdraw their own ETH/tokens directly from their wallet.
- Owner-signed bundles intentionally allow arbitrary calldata to factory-whitelisted targets. That is acceptable only if the product signing UI makes calldata effects clear.
- Existing Uniswap strategies rely on current pool spot values for planning swaps and deposits. They do not use TWAP or external value oracles.

## Positive Observations

- Owner-signed wallet execution binds signatures to the wallet address, owner, full call array, nonce, deadline, and chain-specific EIP-712 domain.
- Replay protection uses unordered nonce bitmaps and rollback semantics keep failed bundles from burning nonces.
- `_execute` checks aggregate ETH value before dispatch and reverts the entire bundle on any failed call.
- Wallet execution is `nonReentrant`.
- `HiroSeason.redeem` burns before unwrapping/sending ETH, but the function is `nonReentrant` and full transaction revert restores burns if ETH transfer fails.
- `UniV3AutoCompoundStrategy` accounts for unpoked V3 fees using fee-growth math and validates max slippage/impact inputs.

## Verification Performed

Commands run:

```sh
forge test --offline --no-match-contract 'Fork|HiroSeasonTest'
forge build --offline
```

Results:

- Offline unit tests passed: 133 passed, 0 failed.
- Build completed successfully.
- Build emitted Foundry lint notes/warnings, mostly style/import naming and test-only unchecked-call warnings. No production compile error was observed.

Not run:

- Fork/integration tests requiring live Base RPC/network access, including `HiroSeasonTest` and strategy fork tests.
- Dedicated PoC tests for the findings above.

