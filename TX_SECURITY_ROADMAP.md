# TX_SECURITY_ROADMAP.md — From Hot Agent Keys to Owner-Signed Execution

## Status (as of branch `solidity-0820-upgrade`)

The **contract layer is built and tested**: Phases 1–2 (HiroWallet v2 + HiroFactory
v2) are implemented in `src/HiroWallet.sol` / `src/HiroFactory.sol` with full coverage
in `test/HiroWallet.t.sol` / `test/HiroFactory.t.sol`. The old global `agents` mapping
and `execute(targets,data,eth)` surface are gone. Remaining work is **off-chain**
(Phase 3 API in `hiro-api`, Phase 4 frontend in `hiro-frontend`) plus the final
test/audit/deploy phases. Per-phase status is in the [Sequencing](#sequencing) table.

## Background

Today, `HiroWallet.execute()` checks only that `msg.sender` is registered in
the factory-level `agents` mapping. That mapping is global, so any single
agent key can call `execute()` on every wallet ever deployed. A key
compromise is a TVL-wide event.

The end state we are committing to:

> No off-chain key — agent, relayer, API server, KMS, factory admin —
> can drain wallets at rest, en masse, or over time. Authority lives in
> the wallet owner's signature. A compromised frontend bounds an attack
> to a single user's wallet contents at sign time, plus any persistent
> allowance the user is tricked into granting. Mass drain is structurally
> impossible because mass signing is. Everything else is detection and
> response.

## Threat model

We are explicit about what each attack class can and cannot reach:

| Compromise | Without this roadmap | With this roadmap |
|---|---|---|
| Agent key, relayer key, API box, KMS | Drains every wallet ever deployed | Zero. Off-chain keys are not signing authorities. |
| Factory admin keys (multisig) | Equivalent to agent key — drains everything | Cannot drain alone. Combined with a frontend compromise, bounded to single-user drain via a newly whitelisted target. Cannot drain at rest, en masse, or over time. |
| Single user's frontend session | Drains every wallet ever deployed | Bounded to that user's wallet contents at sign time. Persistent allowance via signed `approve(attacker, ...)` is reachable; defended operationally, not in the contract. |
| Owner key | Drain via direct `withdraw` | Same. Out of scope. |
| Bad trades (slippage, low-float pool routing, reckless borrow) inside a single signed bundle | Possible | Possible. Accepted — bounded by sign-time wallet contents. |

The load-bearing claim: **no off-chain key, alone or in combination,
can drain wallets at rest, en masse, or over time.** A coincident
admin + frontend compromise can damage *one user at a time, at sign
time*. Everything outside that envelope — persistent allowance via a
signed approve, single-bundle drain via a signed transfer, bad trades —
is bounded to one user per signing event and is defended operationally
(server integrity, bundle simulator, factory pause), not in the wallet.

The deliberate non-goal: defending against bad-but-self-returning trades.
Any framework that tried to would require per-protocol value oracles and
would create constant false-positive friction on legitimate use. We trade
that for a tight, comprehensible defense surface.

## Migration posture

Hiro wallets are non-upgradeable CREATE2 clones. There is no live TVL we
need to preserve at the time of this writing, so this roadmap is written
for a **clean break**: a new factory and a new wallet implementation, with
the old factory deprecated rather than migrated.

If that posture changes later, retrofitting becomes a fund-migration tool
per existing user. Not in scope here.

## The defense

One signing authority, one bounded surface, one kill switch.

**Owner-signed bundles** are the load-bearing change. `HiroWallet.executeWithOwnerSig`
verifies an EIP-712 signature from the wallet owner over the exact bundle
being executed. `msg.sender` is no longer the source of authority. Any
off-chain key — agent, relayer, KMS — can only relay bundles the owner
already signed. Mass drain is structurally impossible because mass signing is.

**Target whitelist** bounds the attack surface to known protocols. A
compromised frontend can only induce signing toward addresses the factory
recognizes (Uniswap routers, Aave pool, ERC20 tokens for approvals, etc.).
The whitelist is multisig-mutable on the factory; adds and removes apply
immediately. No timelock.

**Factory pause** is the kill switch. A single `paused` flag on the factory,
checked in `validateCall`, halts every wallet's execution in one tx.
Multisig-gated, immediate, no timelock.

That is the entire contract-layer defense. We are explicitly **not**
defending in the contract against:

- **Persistent allowance via signed `approve`.** A compromised frontend
  can convince a user to sign `USDC.approve(attacker, MAX)` or
  `Permit2.approve(USDC, attacker, ...)`. The earlier draft of this
  roadmap proposed a `spenderAllowlist` + `ApprovalPolicy` to close
  this. We removed that layer because it only works as long as factory
  admin keys are not compromised — which collapses into the very class
  of "off-chain key compromise causes mass drain" that this roadmap
  was built to eliminate. The marginal defense was conditional on the
  same key security the design was meant to make irrelevant.
- **Single-bundle drain via signed `transfer` / swap recipient.**
  Bounded by sign-time wallet contents.

For both of the above, defense lives in the product surface: the bundle
simulator surfaces persistent-grant calls and unfamiliar recipients
prominently in the confirmation card, and server/frontend integrity is
hardened. The contract does not try to become a protocol-specific policy
engine.

## Target flow

```
Agent reasons about intent
    │
    ▼
API assembles exact bundle: { calls[], nonce, deadline }
    │
    ▼
API returns EIP-712 typed data + readable transaction card to UI
    │
    ▼
User reviews card → clicks "Approve" → wallet prompts signTypedData
    │
    ▼
Owner signs (EOA at launch; ERC-1271-capable verifier in contract)
    │
    ▼
Bundle + signature submitted
    ├── default: API relayer pool pays gas
    └── fallback: owner's EOA pays gas (same signed bundle)
    │
    ▼
HiroWallet.executeWithOwnerSig:
    1. block.timestamp ≤ deadline
    2. nonce unconsumed → consume
    3. EIP-712 digest validates against owner via OZ SignatureChecker
    4. for each call: HiroFactory.validateCall(target)
       (factory checks: !paused && (targetWhitelist[target] || target == this))
    5. dispatch
```

Two observations baked into this flow:

1. **Anyone can submit a signed bundle.** The contract does not check
   `msg.sender`. Relayers are pure gas-payers; they exist for UX, not
   authority.
2. **Owner can bypass signatures entirely.** A separate `executeAsOwner`
   entry point lets the owner submit calls directly from their EOA, no
   typed-data ceremony. This is the liveness escape hatch when the
   relayer pool is unhealthy. It still goes through `factory.validateCall`
   — the pause and target whitelist apply regardless of entry point.

## Do we still need relayers?

The contract does not require them. Keep them as an optimization, not an
authority:

- **Gasless onboarding.** Users without ETH on Base can trade.
- **Retry and rebroadcast.** A stuck tx in mempool can be re-broadcast at
  higher gas without re-signing.
- **Concurrency.** With random 256-bit nonces, the relayer pool can
  submit multiple bundles for the same wallet in parallel.

But the **owner self-submit path must exist** as an unconditional fallback:

- The relayer pool is centralized infrastructure that can fail.
- A compromised relayer can replay user-signed bundles within their
  deadline. Mitigated by short deadlines; user's own EOA is always the
  alternative.

## Contract design

### HiroWallet v2

```solidity
struct Call {
    address target;
    bytes data;
    uint256 value;
}

contract HiroWallet is EIP712, ReentrancyGuard {
    address public immutable owner;
    address public immutable factory;

    // Permit2-style unordered nonces. word = nonce >> 8, bit = nonce & 0xff.
    mapping(uint256 => uint256) public nonceBitmap;

    bytes32 private constant CALL_TYPEHASH = keccak256(
        "Call(address target,bytes data,uint256 value)"
    );
    bytes32 private constant EXECUTE_TYPEHASH = keccak256(
        "Execute(address wallet,address owner,Call[] calls,uint256 nonce,uint256 deadline)"
        "Call(address target,bytes data,uint256 value)"
    );

    function executeWithOwnerSig(
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        require(block.timestamp <= deadline, "expired");
        _consumeNonce(nonce);

        bytes32 structHash = keccak256(abi.encode(
            EXECUTE_TYPEHASH,
            address(this),
            owner,
            _hashCalls(calls),
            nonce,
            deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        require(_isValidOwnerSig(digest, signature), "bad sig");

        _execute(calls);
    }

    function executeAsOwner(Call[] calldata calls) external nonReentrant {
        require(msg.sender == owner, "not owner");
        _execute(calls);
    }

    function invalidateNonce(uint256 nonce) external {
        require(msg.sender == owner, "not owner");
        _consumeNonce(nonce);
    }

    function _execute(Call[] calldata calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            IHiroFactory(factory).validateCall(calls[i].target);
            (bool ok, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(ok, "call failed");
            emit Executed(calls[i].target, calls[i].value);
        }
    }
}
```

Decisions captured above:

- **Bitmap nonces.** Out-of-order consumption is supported. Borrowed from
  Permit2.
- **`Call[]` in the typed-data message.** Field-by-field rendering in
  MetaMask. Note: in practice browser-extension wallets render nested
  struct arrays poorly. We do not count typed-data review as a primary
  defense layer.
- **`executeAsOwner`.** Liveness escape hatch. Still gated by
  `validateCall` (pause + target whitelist) even when the owner signs
  directly.
- **`invalidateNonce`.** Cancel primitive.

### HiroFactory v2

Two pieces of mutable state, both gated by a multisig admin (no
timelock):

```solidity
contract HiroFactory {
    bool public paused;
    mapping(address => bool) public targetWhitelist;
    address public admin; // multisig

    function validateCall(address target) external view {
        require(!paused, "paused");
        require(targetWhitelist[target] || target == address(this), "target not whitelisted");
    }

    function addTarget(address) external; // onlyAdmin
    function removeTarget(address) external; // onlyAdmin — see "Adding and removing protocols"
    function pause() external; // onlyAdmin — immediate
    function unpause() external; // onlyAdmin
}
```

- **Drop the `agents` mapping.** No more global authority.
- **No `spenderAllowlist`, no `approvalPolicy`.** A deliberate
  simplification — see "The defense" above for why those layers were
  cut.
- **`paused`** is the kill switch. Multisig-gated, immediate. Unpause
  is also immediate — the multisig is the trust boundary, not a
  timelock delay.

## Adding and removing protocols

The wallet contract is permanent. The factory whitelist is
multisig-mutable so new protocols do not require wallet redeploys.

- Adding a target: multisig calls `addTarget`, then the API may start
  emitting bundles to that target.
- Deprecating a target: the API stops emitting new bundles. The target
  can remain whitelisted so existing positions are not stranded.
- Removing a target: reserved for emergencies where the target itself is
  unsafe. Removal can strand positions, but leaving a hostile target
  callable is worse.
- Emergency pause: multisig calls `pause`; all wallet execution stops
  until the multisig calls `unpause`.

## API design

Where execution used to live, build-and-return-a-proposal now lives.

- **Each skill's `handleToolCall`** still builds the same `(targets, data,
  values)` triple, but returns a `Proposal`:
  ```ts
  type Proposal = {
    calls: Array<{ target: Address; data: Hex; value: bigint }>;
    nonce: bigint;       // random 256-bit
    deadline: bigint;    // now + 5 min
    typedData: TypedData; // ready for signTypedData
  };
  ```
- **Confirmation flow** becomes a three-step exchange:
  - SSE event `tool_confirmation_required` — unchanged: human-readable card.
  - `POST /api/chat/confirm { confirmationId, approved: true }` —
    resolves the in-memory confirmation; backend assembles the proposal
    and emits `signature_required` with the typed data.
  - `POST /api/chat/submit-signed { confirmationId, signature }` —
    backend sanity-checks via `recoverTypedDataAddress`, persists, hands
    off to relayer.
- **Nonce allocation.** Random 256-bit per proposal. With bitmap nonces,
  abandoned proposals leave no gaps and no birthday-collision risk in
  practice.
- **Bundle simulator.** Before returning a proposal, the API runs the
  bundle through `eth_call` against current state and includes the
  expected after-state in the confirmation card. Persistent-allowance
  calls (`approve`, `increaseAllowance`, `Permit2.approve`,
  `setApprovalForAll`) and outbound transfers to unfamiliar recipients
  are surfaced prominently with the grantee/recipient address called
  out — this is the operational defense for the persistent-allowance
  and single-bundle-drain attack classes that the contract no longer
  closes. The simulator does not defend against a fully compromised
  frontend that lies about results; that's where the factory pause and
  out-of-band monitoring take over.
- **Relayer pool = today's agent pool**, with authority stripped:
  - It signs `executeWithOwnerSig(bundle, sig)`, not `execute()`.
  - Per-key `pendingTx` serialization stays — that's the relayer EOA's
    own nonce, independent of the wallet's signing nonce.
- **New Mongo collection `signedBundles`**:
  ```ts
  {
    confirmationId, walletAddress,
    bundleHash, calls, nonce, deadline, signature,
    status: 'pending' | 'submitted' | 'confirmed' | 'failed' | 'expired',
    submittedBy?: Address,
    txHash?: Hex,
    lastError?: string,
    createdAt, updatedAt
  }
  ```
  TTL index drops entries past `deadline + 24h`.
## Frontend design

The confirmation UX should not gain a noticeable extra step. Press
"Approve," wallet pops, sign, transaction appears in history.

- **`src/lib/typedData.ts`** (new, mirroring `src/lib/siwe.ts`): builds
  the `Execute` typed data. Domain: `name: "HiroWallet"`, `chainId:
  activeChain.id`, `verifyingContract: walletAddress`.
- **`src/types/chat.ts`** gains `SSESignatureRequiredEvent` and
  `PendingSignature` shapes.
- **`ConfirmationCard.handleConfirm`** evolves:
  1. Verify chainId; switch via `useSwitchChain` if not.
  2. POST `/api/chat/confirm`.
  3. On `signature_required` SSE event, call `useSignTypedData().signTypedDataAsync`.
  4. POST `/api/chat/submit-signed`.
  5. Surface `submitted` → `txHash` → `confirmed` from SSE.
- **"Submit with my wallet" toggle.** Skips typed-data step, uses
  `useWriteContract` to call `executeAsOwner(calls)` from the user's EOA.
  Default off. Liveness fallback.

## Edge cases

### Signing and identity

- **Signature validation.** Use OpenZeppelin `SignatureChecker` so EOA
  owners validate through ECDSA and future smart-contract owners validate
  through ERC-1271 without adding a second wallet execution path. Product
  support at launch remains EOA-only.
- **Owner key rotation.** `HiroWallet.owner` is immutable. Rotation =
  new wallet, move funds.
- **Signature malleability.** OZ `SignatureChecker` uses `ECDSA` for EOA
  signatures, which rejects high-s.
- **Wrong-chain signing.** EIP-712 domain pins chain id.

### Replay and ordering

- **Cross-wallet replay.** Domain `verifyingContract = address(this)`.
- **Cross-chain replay.** Domain chain id.
- **Cross-nonce replay.** Bitmap consumption is a state write.
- **Cancellation.** `invalidateNonce(uint256)`. Owner-only. Wrappable
  into a gasless signed cancel.
- **Concurrent proposals.** Random nonces; arbitrary parallelism.

### Liveness

- **Relayer pool down.** Owner submits `executeWithOwnerSig` from their
  own EOA — same bundle, same sig — or calls `executeAsOwner`.
- **Relayer censorship.** Same fallback.
- **Relayer races.** First to land wins the nonce; loser reverts and
  wastes their own gas. Mitigation: relayer pool marks `bundleHash` as
  `submitted` in Mongo before broadcast.
- **Stuck tx.** Rebroadcast with higher gas; no new signature needed.

### State drift between sign and submit

- **Slippage, health factor changes.** Tx reverts on protocol's own
  minOut / HF check, no funds move. Deadlines ≤ 5 minutes cap exposure.
- **MEV / sandwich.** Slippage, price-impact guards, and short deadlines
  bound execution. Relayers submit to the public mempool.

### Frontend compromise (accepted threat model)

- **Hostile frontend induces a sign on a draining bundle.** Possible.
  Bounded by sign-time wallet contents. Response: factory pause + bundle
  simulator surfacing the malicious calls in the confirmation card.
- **Hostile frontend slips in `approve(attacker, MAX)` or
  `Permit2.approve(attacker, ...)`.** Possible at the contract layer.
  Persistent allowance once granted survives until the user signs a
  bundle revoking it (or migrates wallet). Defended operationally via
  bundle simulator highlighting the approval call's grantee and
  server/frontend integrity. Explicitly not
  defended in the contract — see "The defense" for the reasoning.

### Atomicity and batching

- **Approve + swap in same bundle.** Same `Call[]`, atomic.
- **Partial submission.** Impossible. Bundle is the execution unit.

### Reorg

- A confirmed tx that reorgs out leaves the nonce consumed off-chain
  but unconsumed on-chain. Relayer detects via receipt re-check and
  rebroadcasts.

## Sequencing

| Phase | Status | What | Why this order |
|---|---|---|---|
| 1 | ✅ DONE | HiroWallet v2: `executeWithOwnerSig`, `executeAsOwner`, OZ `SignatureChecker`, bitmap nonces, `invalidateNonce`, full test coverage | Signature layer is load-bearing. |
| 2 | ✅ DONE | HiroFactory v2: `paused`, `targetWhitelist`, multisig admin, immediate pause/unpause | Mutable registry that the wallet calls into. |
| 3 | 🚧 IN PROGRESS (`hiro-api`) | API: per-skill `Proposal` return shape, nonce allocator, `signedBundles` collection, bundle simulator surfacing approval calls and outbound transfers, relayer pool repurposed to gas-pay only | Backend produces signable bundles; operational defense lives here. |
| 4 | ⬜ TODO (`hiro-frontend`) | Frontend: `lib/typedData.ts`, `SSESignatureRequiredEvent` wiring, `useSignTypedData` in `ConfirmationCard`, chain enforcement, self-submit toggle, approval-call call-out in the confirmation card | UX end-to-end. |
| 5 | ⬜ TODO | E2E tests on Base fork, Slither pass, audit window on wallet + factory | Verify before deploy. |
| 6 | ⬜ TODO | Deploy v2 factory + v2 wallet impl + admin multisig to Base. Deprecate v1 factory. | Ship. |

## Out of scope

- **Bad trades within the accepted envelope** — slippage, low-float pool
  routing, reckless borrows, LP-range griefing, direct
  `ERC20.transfer(attacker, x)`. All bounded by sign-time wallet contents.
- **Persistent allowance via signed `approve`.** Bounded to one user per
  signing event. Defended operationally by clear decoded-call display,
  not in the contract. See "The defense" for the reasoning.
- **Upstream protocol bugs** in Aave, Uniswap.
- **Owner private key compromise.** Already a draining vector through
  `withdraw`. Neutral.
- **Non-Base chains, bridging.**

## Open questions

1. **Admin multisig composition.** The admin key gates `addTarget`,
   `removeTarget`, `pause`, `unpause`. It must be reachable 24/7 because
   pause is the kill switch. Recommend 2-of-N where N is the on-call
   rotation for pause-tier actions; a higher-quorum board for
   `addTarget` would add friction without changing the threat model
   (the two-factor compromise envelope is what's accepted), so the same
   multisig serves both purposes. Open to splitting if operational
   experience suggests it.
