# Repository Guidelines

## Project Structure & Module Organization
Core Solidity sources live in `src/`, with deployment automation in `script/` (for example `script/Deploy.s.sol`) and Forge tests in `test/` (`HiroWallet.t.sol`, `HiroFactory.t.sol`). Reusable artifacts such as ABIs sit in `abi/`, deployment logs in `broadcast/`, and vendored dependencies inside `lib/`. Large JSON assets (allowlists, cached calls) belong in `whitelist.json` or `cache/` so `src/` stays focused on contracts. Keep `foundry.toml` and `remappings.txt` updated whenever you add a dependency or adjust compiler settings.

## Build, Test, and Development Commands
Run `forge build` for a full compile using the repository’s remappings. `forge test` executes every suite; narrow scope with `forge test --match-contract HiroWalletTest` to shorten feedback loops. Capture gas deltas via `forge snapshot` before and after optimizations. The Makefile wraps common workflows: `make fork` launches Anvil against the Base RPC, `make deploy` runs `Deploy.s.sol` against the local fork, and `make approve-factory` / `make create-wallet` send scripted Cast transactions. Use `cast call` or `cast send` for ad-hoc contract interactions.

## Coding Style & Naming Conventions
Stick to Solidity 0.7.6 (the repo pins `pragma solidity =0.7.6;`) with 4-space indentation. Contracts, libraries, and scripts use PascalCase (`HiroFactory`, `Deploy`), while functions and variables are mixedCase and constants remain UPPER_SNAKE. Favor small libraries in `src/libraries/` when logic is shared. Always run `forge fmt` before committing; it enforces canonical spacing, import ordering, and doc-comment alignment.

## Contract Behavior Snapshot
- `HiroFactory` deploys one `HiroWallet` per owner and maintains global agent + whitelist registries. Wallet creation no longer requires a setup fee, and there are still no per-operation charges.
- `HiroWallet` exposes a single `execute(address[] targets, bytes[] data, uint256[] values)` function for agents. It validates array lengths, checks the factory whitelist for every target, confirms enough ETH is available, and then forwards each call. No gas-percentage or swap fees are assessed.
- Wallet owners can withdraw arbitrary ERC20s and ETH that accumulate in their wallet; agents can never withdraw.

## Testing Guidelines
Tests extend Foundry’s `Test` base and live beside their subject contracts (e.g., `test/HiroFactory.t.sol`). Name test methods after the behavior (`testExecuteRevertsOnLengthMismatch`) and include failure paths plus event emission checks. The current unit suites use a local Anvil instance without forking or environment variables. Add fork-based tests only when integration coverage is required.

## Commit & Pull Request Guidelines
Recent history shows concise, imperative subjects (`batchExecute`, `fix deploy`). Mirror that format, keep subjects under 72 characters, and add a short body when context is non-obvious (behavior flags, storage migrations, gas impacts). Every PR should explain motivation, summarize contract or script changes, call out new configuration files, and link to issues or specs. Include `forge test` output or gas snapshot diffs for visibility, and request at least one review before merge.

## Security & Configuration Tips
Never commit private keys or RPC URLs; load them through environment variables consumed by Forge and Cast (the Makefile accepts `--rpc-url`/`--private-key`). When editing `whitelist.json` or other governance lists, document provenance and validate against `cast call` on an Anvil fork before broadcasting. Double-check chain IDs (`31338` for the local fork) in scripts, and rerun `make deploy` against a fork prior to hitting mainnet to ensure bytecode and constructor args match expectations.
