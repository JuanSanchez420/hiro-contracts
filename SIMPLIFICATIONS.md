# Contract Simplifications

Goal: make the Hiro contracts easier to reason about while preserving the controls
that actually matter. Prefer simple, relative, protocol-native checks over precise
cross-asset accounting. Accept small edge-case imprecision when it removes an
oracle, a mutable policy surface, or a hard-to-audit math path.

## High-Value Simplifications

### 1. Keep compound thresholds oracle-free

The current `UniV3AutoCompoundStrategy` direction is right: only compound when
the wallet-bound fees are meaningful relative to the position itself.

Instead of "compound when fees are worth at least $5", use:

```text
fee value >= minCompoundBps * current position principal
```

Both sides are valued in the position's own tokens at the same pool price. This
keeps the check:

- pool-agnostic;
- oracle-free;
- independent of token decimals in the trigger interface;
- aligned with the user's actual position size.

This is more robust than a USD floor. It avoids stale oracle reads, missing feeds,
oracle decimals, feed governance, and per-chain deployment differences. It also
scales naturally: a large LP waits for larger fees, while a small LP does not need
to hit an arbitrary dollar threshold.

Recommendation: use this pattern for strategy triggers generally. Prefer "is this
action meaningful relative to the thing being managed?" over "is this worth X USD?"
unless the product truly needs dollar accounting.

### 2. Reduce strategy call parameters

The strategies currently accept caller-provided `slippageBps` and `maxImpactBps`
on every execution. That is flexible, but it expands the runtime surface and makes
every agent call carry policy decisions.

For an 80/20 version:

- `CompoundParams`: only `positionId`.
- `RebalanceParams`: `positionId`, `newTickLower`, `newTickUpper`.
- Slippage and impact limits become immutable deployment config, or hardcoded
  conservative constants per strategy.

The existing hard caps are good, but routine values probably do not need to be
runtime parameters. If Hiro wants different profiles later, deploy multiple
strategies, for example `ConservativeRebalanceStrategy` and
`AggressiveRebalanceStrategy`, and whitelist only the ones the product supports.

Benefits:

- smaller ABI;
- less agent discretion;
- less calldata to validate and test;
- clearer review surface for strategy whitelisting.

Tradeoff: changing the standard slippage policy requires deploying a new strategy
or updating off-chain routing to a different whitelisted strategy. That is usually
acceptable because these values are protocol policy, not per-call user intent.

### 3. Prefer one-time approvals over per-execution approvals

Both Uniswap V3 strategies currently emit ERC20 `approve` calls before swaps and
liquidity changes. This is explicit, but it adds calls to every strategy execution
and increases the number of whitelisted target interactions.

Simpler path:

- when a Hiro-managed position is created, approve NPM and SwapRouter once;
- strategies assume those approvals exist;
- imported positions without approvals simply fail until the user opts them into
  the Hiro-managed path.

This matches the existing product posture: strategy opt-in is
implicit via pre-approvals. The implementation can lean into that instead of
making every strategy bundle self-sufficient.

Benefits:

- fewer calls per compound/rebalance;
- less gas;
- fewer allowance state changes;
- simpler call sequences to inspect.

Tradeoff: this is less universal for arbitrary imported LP NFTs. That is a good
trade if the primary product path is Hiro-created or Hiro-onboarded positions.

### 4. Simplify protocol fee collection

The protocol fee split is one of the biggest sources of strategy complexity.
Auto-compound needs fee-growth math because `positions().tokensOwed*` undercounts
fees since the last poke. Rebalance uses a simpler path because decreasing
liquidity pokes the position.

There are three possible approaches:

1. Keep the current strategy fee split.
   This preserves the 10% protocol-fee economics, but accepts the ongoing math and
   test burden.

2. Make the fee split deliberately approximate.
   For example, charge only against currently materialized `tokensOwed*`, and do
   not try to recover every unpoked wei. This is simpler but leaks some protocol
   fee until a later operation realizes it.

3. Remove strategy-level protocol fee splitting.
   Route all strategy output to the wallet and collect Hiro revenue through a
   simpler product-layer mechanism.

The most elegant contract-layer option is 3. The most conservative business option
is 1. Option 2 is the 80/20 middle: keep protocol fees, but explicitly stop trying
to be exact in every Uniswap V3 accounting edge case.

Recommendation: choose one of these intentionally. Avoid adding more accounting
machinery unless exact protocol-fee capture is economically material.

### 5. Simplify season buybacks

`HiroSeason.executeBuyback()` currently calculates expected HIRO output from a
5-minute TWAP, applies slippage, and also sets a sqrt price limit. The price limit
is the stronger and simpler control.

For an 80/20 version, make price movement the primary protection:

- keep `priceImpactBps`;
- use `_calculatePriceLimit()`;
- set `amountOutMinimum` to `0` or to a very coarse floor;
- remove TWAP output estimation if the product can tolerate less precise buyback
  accounting.

This removes:

- TWAP observation-cardinality assumptions;
- TWAP availability edge cases;
- duplicated price math;
- tests that depend on observation history.

The tradeoff is that the buyback no longer guarantees a precise minimum output.
It still cannot move beyond the configured price limit, which is the protection
that matters most for avoiding bad execution.

### 6. Avoid relying on active LP fee collection

`HiroSeason.collectFees()` calls `collect()` directly. In Uniswap V3, this only
collects fees already owed to the position; it does not necessarily realize all
fees accrued since the last position update.

Simpler product stance:

- do not depend on active fee collection for correctness;
- treat buybacks from collected fees as opportunistic;
- rely on final liquidity withdrawal and redemption accounting to realize the
  season's value.

If active buybacks from LP fees are important, then the contract needs deliberate
poke/realization behavior. That adds complexity. The simpler, robust stance is:
active buybacks are nice-to-have, final redemption is load-bearing.

### 7. Replace magic sqrt constants with TickMath

`HiroSeason` currently hardcodes initial sqrt prices for ticks near `-100020` and
`100020`. The comments explain the intent, but the constants still create a review
burden.

Simpler:

```solidity
sqrtPriceX96 = TickMath.getSqrtRatioAtTick(initialTick);
```

Keep the ticks as named constants:

```text
INITIAL_TICK_HIRO_TOKEN0 = -100020
INITIAL_TICK_HIRO_TOKEN1 = 100020
```

This makes the bootstrap behavior auditable from the tick intent, not from a large
numeric constant.

### 8. Make range width guards spacing-relative

`UniV3RebalanceStrategy` uses raw tick width constants:

- `MIN_WIDTH_TICKS = 200`;
- `MAX_WIDTH_TICKS = 60000`.

These are easy to test, but they are less intuitive across fee tiers because V3
tick spacing changes by pool fee.

Simpler policy:

```text
min width = N * tickSpacing
max width = M * tickSpacing
```

This keeps validation aligned with the pool's actual granularity. It also makes
the policy easier to explain: "at least 20 initialized tick steps wide", for
example.

### 9. Improve wallet failure observability

`HiroWallet._execute()` currently reverts with `CallFailed()` and discards revert
data from the target. That is simple, but it makes strategy debugging harder.

A low-complexity improvement:

- include the failed target in the error; or
- bubble the revert data; or
- emit/index enough context before the call sequence that failures can be traced
  from simulation.

This is not a security requirement. It is a developer-experience improvement that
reduces operational ambiguity when a whitelisted strategy fails.

### 10. Consider `sqrtPriceLimitX96` for strategy swaps

`UniV3RebalanceStrategy` and `UniV3AutoCompoundStrategy` currently protect their
internal swaps with spot-derived `amountOutMinimum` values and hard
`maxImpactBps` caps. That is probably enough for the deep pools Hiro targets, and
it keeps the strategy swap path simple.

If strategies are ever pointed at thinner or more volatile pools, add an explicit
Uniswap V3 `sqrtPriceLimitX96` to the `exactInputSingle` calls. That gives the
swap a protocol-native price boundary instead of relying only on output floors.

Recommendation: leave it out while strategies target deep managed pools, but make
it the first safety improvement before supporting shallow pairs, long-tail assets,
or user-selected strategy pools.

## Suggested Priority

1. Keep and document the oracle-free compound threshold.
2. Remove per-call strategy slippage/impact parameters.
3. Rely on one-time approvals for Hiro-managed positions.
4. Decide whether exact strategy-level protocol fee splitting is worth its
   complexity.
5. Simplify `HiroSeason` buybacks to price-limit-first execution.
6. Replace initial sqrt magic constants with `TickMath`.
7. Convert rebalance range width bounds to tick-spacing-relative values.
8. Improve wallet call failure diagnostics.
9. Add `sqrtPriceLimitX96` to strategy swaps before supporting thin pools.

## Tests For Future Implementations

If these recommendations are implemented later, keep tests focused on the changed
behavior:

- auto-compound rejects tiny fees using the relative position-size threshold;
- compound no longer needs a USD oracle or token-specific notional setting;
- strategies work when approvals already exist and fail cleanly when they do not;
- strategy params shrink without weakening ownership, whitelist, slippage, or
  impact protections;
- buyback respects the configured price limit without relying on TWAP output math;
- initial season pool price equals `TickMath.getSqrtRatioAtTick(initialTick)`;
- rebalance width validation behaves correctly across at least two fee tiers;
- wallet execution failures identify the failing call well enough to debug.
- strategy swaps respect `sqrtPriceLimitX96` when that guard is added.

## Operating Assumptions

- Hiro optimizes for a clean managed path, not universal support for every possible
  imported position.
- The factory pause, target whitelist, strategy whitelist, hard strategy caps, and
  off-chain monitoring are the primary safety controls.
- Small economic imprecision is acceptable when it removes oracle dependencies,
  mutable policy surfaces, or complex accounting.
- Final redemption correctness matters more than opportunistic mid-season buyback
  precision.
- New strategies are cheap to deploy compared with making one strategy runtime
  configurable for every future policy preference.
