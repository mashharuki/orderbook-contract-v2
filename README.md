# Sera Orderbook Contract (v2)

> Required Notice: Copyright 2025 Working Ants Inc. (Panama)

This repository contains **Solidity + Foundry** based order book matching contracts with vault custody, EIP-712 signatures, and dual-authorization withdrawals.

**Core Contracts:**
- **`Sera.sol`**: Core order book logic with EIP-712 signed order matching, vault custody, and dual-authorization withdrawals
- **`SeraAdmin.sol`**: Abstract admin base (treasury, whitelist, slippage sharing, pause, rescue)
- **`SeraLib.sol`**: Shared structs (`Order`, `MatchData`, `WithdrawIntent` (SOR withdrawal)), typehashes, and pure math functions
- **`SeraBase.sol`**: Abstract base contract for execution wrappers (Access Control + Pause Modifier + cached EXECUTOR_ROLE)
- **`SeraBatcher.sol`**: Unified batch wrapper — best-effort (`batchMatchOrders`) + fill-or-kill (`batchMatchOrdersAtomic`) + mixed mode with SOR execution support (`batchMatchMixed`). References both `Sera` and `SeraSOR`.
- **`SeraSOR.sol`**: Smart Order Router for multi-leg atomic route matching with transient balance optimization
- **`Vault.sol`**: Asset custody with per-user balances, blacklist controls, and ledger transfers
- **`interface/IVault.sol`**: Vault interface definition

**Known Limitations:**
- Fee-on-transfer (FoT) tokens are not supported. The Vault credits the requested amount directly and does not measure post-transfer balance deltas. Only standard ERC20 tokens should be whitelisted.
- Rebasing / elastic supply tokens (e.g., stETH, AMPL) are not supported. The Vault tracks balances via a `trackedBalance` mapping that would diverge from the physical balance of rebasing tokens, leading to trapped yield or insolvency.

**Key Features:**
- ✅ **SOR-Based Matching**: Orders are signed off-chain and matched on-chain (gas efficient, no cancellation fees)
- ✅ **Vault Custody**: Funds are locked in `Vault.sol` ensuring solvency before execution
- ✅ **EIP-712 Signatures**: Secure typed data signing for orders and withdrawals, with EIP-1271 support for smart contract wallets (Safe, Argent, ERC-4337 accounts)
- ✅ **Dual-Authorization Withdrawals**:
  - **Delayed**: User-initiated via `emergencyWithdraw()`, 7200 blocks (~24h) delay with 14400 blocks (~48h) expiration
  - **Instant**: Dual-signature (`executeInstantWithdrawDualSig`) with user + executor EIP-712 signatures
- ✅ **Smart Order Routing (SOR)**: Multi-leg atomic routing via `SeraSOR.executeIntent()` with SOR-based signing. The taker signs an `IntentParams` (SOR parameters) struct covering `(taker, inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)`. The `taker` field cryptographically binds the signer's identity inside the EIP-712 struct, enabling EIP-1271 smart contract wallet support. The executor constructs optimal route legs freely, but the signed envelope must carry non-zero bounds (`maxInputAmount > 0`, `minOutputAmount > 0`). Features include transient balance optimization (via `uniqueTokenCount`), signed wallet funding via `initialDepositAmount`, enforced output destination via signed `recipient`, and strict `TransientBalanceNotZero` enforcement for intermediate balances.
- ✅ **Dynamic Fee Structure**: Per-order configurable `feeBps` (uint48) with expanded `BPS_DENOMINATOR = 1e14` for sub-basis-point granularity (e.g. $0.01 fee on $1M orders) + configurable slippage sharing via `SlippageShare` struct (maker/taker/protocol split)
- ✅ **Signature Caching**: Signature-checked order flows cache first-fill authentication in `filledAmount`, so subsequent partial fills of the same authenticated order skip redundant EIP-712 verification via `SignatureChecker` (supports both EOA `ecrecover` and EIP-1271 contract signatures)
- ✅ **Transient Reentrancy Guard**: `ReentrancyGuardTransient` on all `Sera.sol` entry points — locks use transient storage (EIP-1153), lasting only for the cross-contract execution duration
- ✅ **Ghost Liquidity Prevention**: Vault balance checked on every match
- ✅ **Frozen User Policy**: Compromised accounts can be frozen (stops trading/deposits) but CAN withdraw
- ✅ **Partial Fills**: On-chain tracking of filled amounts for reusable signature-checked order hashes; routed taker intents are instead bounded by signed envelopes and per-intent UUIDs
- ✅ **Token Whitelist**: Governance-controlled whitelist with per-token minimum order amounts

---

## Modular Documentation Index
For detailed documentation on integrations, architecture, and security, see the guides in the `readme/` folder:

1. **[Architecture Overview](readme/architecture.md)** — Wrapper routing, settlement flow, and structural execution.
2. **[Security Overview](readme/security.md)** — Documentation covering non-custodial extraction boundaries, blacklisting limitations, Reentrancy handling, and ghost liquidity.
3. **[Audit FAQ](readme/audit_faq.md)** — Deliberate design choices and "gas-over-verify" patterns explained for security auditors.
4. **[Test Suite Summary](test/summary.md)** — Detailed audit summary of every test suite, counts, and assertions.
5. **[Security Audits](audits/)** — Third-party audit reports (PDF).

---

## Directory Structure
```
orderbook-contract-v2/
├── src/
│   ├── Sera.sol              # Core orderbook (matching + settlement + withdrawals)
│   ├── SeraAdmin.sol         # Abstract admin base (treasury, whitelist, slippage, pause, rescue)
│   ├── SeraLib.sol           # Shared structs (Order, MatchData, WithdrawIntent (SOR withdrawal)), typehashes, pure math
│   ├── SeraBase.sol          # Abstract base for wrappers (cached EXECUTOR_ROLE)
│   ├── SeraBatcher.sol       # Unified batch execution wrapper (best-effort + FOK + mixed)
│   ├── SeraSOR.sol           # Smart Order Router (multi-leg atomic routing with transient balances)
│   ├── Vault.sol             # Asset custody contract with ledger transfers
│   ├── interface/
│   │   └── IVault.sol        # Vault interface
│   └── mock/
│       ├── MockStableCoin.sol         # Testing ERC20 token (18 decimals)
│       └── MockStableCoinDecimals.sol # Testing ERC20 with configurable decimals (6/18-dec mixes)
├── test/
│   ├── TestHelper.sol
│   ├── Sera.t.sol
│   ├── SeraBatcher.t.sol
│   ├── SeraRoute.t.sol
│   ├── SeraFuzz.t.sol
│   ├── SeraInvariant.t.sol
│   ├── SeraInvariant034.t.sol         # Vault solvency invariant fuzzing
│   ├── SeraAuditCoverage.t.sol
│   ├── SeraCoverageExtras.t.sol
│   ├── SeraSOR_NonRigid.t.sol         # Core SOR sentinel & routing
│   ├── SeraSOR_AttackVector.t.sol     # Security & attack vectors
│   ├── SeraSOR_Extreme.t.sol          # Extreme spread, fees & dust
│   ├── SeraSOR_EdgeCase.t.sol         # Edge cases & emergency controls
│   ├── SeraSOR_Precision.t.sol        # Precision & arithmetic
│   ├── SeraSOR_AdvancedFuzz.t.sol     # Fuzz tests
│   ├── SeraSOR_OptionB.t.sol          # Universal transient zero-balance / mixed-funding regressions
│   ├── SeraSOR_Topology.t.sol         # Extreme topologies
│   ├── SeraSOR_Settlement.t.sol       # Settlement optimization
│   ├── SeraSOR_SettlementStress.t.sol # Settlement stress tests
│   ├── SeraSOR_Positive_Slippage.t.sol # Positive slippage PoC (stub)
│   ├── SeraSOR_Permit.t.sol           # EIP-2612 permit integration tests
│   ├── SeraSOR_DeepAudit.t.sol        # Deep audit PoC validations
│   ├── SeraSOR_SigBypassPoC.t.sol     # Signature-bypass regression PoC (fixed behavior)
│   ├── SeraSOR_CoverageGaps.t.sol     # Coverage gap tests (diamond, wallet funding)
│   ├── SeraSOR_AttackerSteal.t.sol    # Output hijacking fix validation
│   ├── SeraEIP1271.t.sol              # EIP-1271 smart contract wallet signature tests
│   ├── Sera7702.t.sol                 # EIP-7702 delegated-EOA signature tests
│   ├── Sera_FullCoverage.t.sol        # Full coverage suite
│   ├── SeraBPS_Precision.t.sol        # BPS denominator precision & overflow tests
│   └── summary.md                     # Detailed test audit summary
├── script/
│   ├── Deploy.s.sol              # Mainnet deployment script (timelock-aware)
│   ├── DeployTestnet.s.sol       # Testnet deployment script (with mock tokens)
│   ├── DeploySepolia.s.sol       # Sepolia deployment script with verification
│   ├── DeployAll.s.sol           # Combined deployment script (Vault + Sera only)
│   ├── DeployLocal.s.sol         # Local development deployment
│   └── update-env.sh             # Helper for updating .env after a deploy run
├── vendor/
│   └── compound-timelock/    # Isolated 0.5.16 sub-project compiling the Compound/Uniswap Timelock bytecode
│       ├── foundry.toml
│       ├── LICENSE           # BSD-3-Clause (Compound Labs)
│       └── src/
│           ├── Timelock.sol
│           └── SafeMath.sol
├── readme/                   # Modular documentation
│   ├── architecture.md       # Integration diagrams
│   ├── security.md           # Guard rails and governance
│   └── audit_faq.md          # Deliberate design choices for auditors
└── README.md                 # This file
```

---

## Quick Start

### Prerequisites
- **Foundry** (`forge`, `cast`, `anvil`)
- **Solidity** `0.8.24`

### Build
```shell
forge build
```

### Test
Run all tests:
```shell
forge test
```

### Coverage
```shell
forge coverage
```

### Deploy

Copy `.env.example` to `.env` and fill in `PRIVATE_KEY`, `*_RPC_URL`, and (for mainnet) `TIMELOCK_ADDRESS` after deploying the Compound timelock from `vendor/compound-timelock/`. Then:

```shell
# Local anvil
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url $LOCAL_RPC_URL --broadcast

# Sepolia (with verification)
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Mainnet (transfers admin to TIMELOCK_ADDRESS and renounces deployer admin)
forge script script/Deploy.s.sol:DeployScript --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

`Deploy.s.sol` requires `TIMELOCK_ADDRESS` to point at deployed bytecode; the script reverts otherwise so governance is never orphaned after the deployer renounces `DEFAULT_ADMIN_ROLE`.

### Local protocol walkthrough

Run the complete v2 user-flow walkthrough on an isolated local Anvil chain:

```shell
./script/run-local-experience.sh
```

It deploys a fresh stack and broadcasts real local transactions for Vault deposits, signed direct and partial matches, best-effort and atomic batches, a two-hop SOR route with signed wallet funding, a dual-signature instant withdrawal, the complete delayed-withdraw flow (including Anvil block mining), and pause/unpause protection. Every stage checks its post-conditions and reverts on a failed assertion. The helper only accepts a loopback RPC URL and defaults to Anvil's public development keys; do not provide production keys.

---

## Documentation

All documentation lives in the `readme/` folder. For architecture diagrams, security overview, and audit-facing design notes, reference the Modular Documentation Index above. Detailed test-suite audit notes live in [`test/summary.md`](test/summary.md).

---

## Design Overview

### Architecture

- **Library stack**: Solady's gas-optimized `EIP712` for typed-data hashing; OpenZeppelin's `SignatureChecker` for unified EOA + EIP-1271 smart-contract wallet validation.
- **Order struct**: packed `uint48` for `expiration` and `feeBps`; includes `initialDepositAmount` for signed SOR funding control and `uuid` for replay protection. `BPS_DENOMINATOR = 1e14` provides sub-basis-point fee granularity (e.g. $0.01 fee on $1M orders) within `uint48` storage.
- **Slippage sharing**: configurable profit splits via the `SlippageShare` struct (`makerShareBps`, `takerShareBps`, `protocolShareBps`, `totalBps`).
- **Withdrawal system**: dual-path — a 7200-block delayed emergency path (~24h, with a 14400-block / ~48h expiration window) and an instant dual-signature path requiring user + executor EIP-712 signatures.
- **SOR signed-routing model**: the taker signs an `IntentParams` struct `(taker, inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)` once; the executor constructs optimal route legs freely at execution time. The `taker`, `recipient`, and `initialDepositAmount` fields are cryptographically committed to prevent identity spoofing, output hijacking, and unauthorized wallet pulls. The `taker` field binds the signer's address into the signed struct, enabling EIP-1271 smart-contract wallet support. The routed path requires a non-zero envelope (`maxInputAmount > 0` and `minOutputAmount > 0`), so a taker's signed price bounds can never be silently disabled. Final-leg positive slippage follows the configured `SlippageShare` split. Any leftover intermediate transient balance triggers a `TransientBalanceNotZero` revert, enforcing strict fund conservation.

### Security

- **Permit front-run protection**: `depositFundWithPermit` checks existing allowance before calling permit, neutralizing griefing attempts that race the permit nonce.
- **Ghost liquidity prevention**: vault balance is verified on every match via `_validateMakerOrder` before any state changes.
- **SOR replay protection**: per-user UUID nonce mapping (`isIntentUuidUsed[user][uuid]`) prevents replay without global nonce contention.
- **SOR envelope guards**: taker-signed `maxInputAmount` and `minOutputAmount` cap total spending and floor total output across all route legs, and zero-valued bounds are rejected up front with `ZeroEnvelope`.
- **Signed SOR recipient (diamond-safe)**: `recipient` is signed inside the SOR parameters; every terminal leg's `order0.recipient` is enforced to match. Prevents output hijacking in both linear and split/diamond topologies.
- **Signed SOR wallet funding**: `initialDepositAmount` is signed inside the SOR parameters, so executors cannot modify the wallet-pull amount at execution time. The exact amount signed is the exact amount pulled.
- **Price bounds**: `InvalidCostAmount` and `TokenMismatch` assertions in `SeraLib._executionValues`.
- **`creditLedger` zero-address guard**: `user != address(0)` sanity check in `Vault.creditLedger()` prevents accidentally burning vault balance to the zero address.
- **EIP-712 canonical array encoding**: `executeInstantWithdrawDualSig` hashes `address[]` tokens as 32-byte-padded words (per EIP-712 spec), ensuring compatibility with standard wallets and SDKs.
- **Transient reentrancy guard**: `ReentrancyGuardTransient` on all `Sera.sol` entry points; locks use transient storage (EIP-1153) and last only for the duration of cross-contract execution.

### Gas optimizations

- **SOR transient-memory layout**: `SeraSOR` allocates transient memory using a `uniqueTokenCount` hint passed by the caller, reducing MSTORE memory-expansion penalties during multi-leg route execution.
- `EXECUTOR_ROLE` cached as `immutable` in `SeraBase.sol` (~2100 gas/call).
- Hot calldata fields cached in `_settleRoutedLegInternal`.
- `unchecked` loop increments system-wide where overflow is provably impossible.
- Fail-fast validation order in `_validateOrderCommon`.
- `trackedBalance` cached in `Vault.sol` to avoid double SLOADs.
- `creditLedger` relies on a documented push-then-credit invariant, sidestepping TOCTOU-style multi-trader races.

### Governance

- **Compound Timelock**: the repo ships an isolated sub-project under [`vendor/compound-timelock/`](./vendor/compound-timelock/) that compiles the original Compound/Uniswap `Timelock.sol` (Solidity 0.5.16), so the deployed bytecode matches the battle-tested governance timelock used by Uniswap and others. `Deploy.s.sol` reads `TIMELOCK_ADDRESS` from the environment; if set, it transfers `DEFAULT_ADMIN_ROLE` on both `Vault` and `Sera` to that address before renouncing the deployer's admin, with post-condition asserts so a half-transferred deploy cannot succeed.
- **EIP-1271 / EIP-7702 signers**: maker, taker, and instant-withdraw signature paths all flow through OpenZeppelin's `SignatureChecker`, so smart-contract wallets (Safe, Argent, ERC-4337) and EIP-7702-delegated EOAs are first-class signers.

---

## Security Audit (TLDR)

- **Auditor:** CertiK
- **Report:** [`audits/2026-04-30-certik-sera-final.pdf`](./audits/2026-04-30-certik-sera-final.pdf) — final, dated 2026-04-30
- **Scope:** all first-party contracts under `src/` — `Sera`, `SeraSOR`, `SeraBatcher`, `SeraAdmin`, `SeraBase`, `SeraLib`, `Vault`, and `IVault`. Test fixtures, deploy scripts, mocks, and vendored / third-party libraries (`vendor/compound-timelock/`, `lib/openzeppelin-contracts/`, `lib/solady/`, `lib/forge-std/`) are out of scope.
- **Status:** All in-scope findings have been addressed in the post-audit code. Proof-of-concept tests validating findings live under [`test/SeraSOR_DeepAudit.t.sol`](./test/SeraSOR_DeepAudit.t.sol) and [`test/SeraSOR_SigBypassPoC.t.sol`](./test/SeraSOR_SigBypassPoC.t.sol), with cross-references to the full test surface in [`test/summary.md`](./test/summary.md).
- For severity breakdown, individual findings, and remediation discussion, **see the PDF**.

---

## License

Copyright 2025 Working Ants Inc. (Panama). All rights reserved.

All first-party content in this repository — everything **except** the third-party directories listed under [Third-party components](#third-party-components) below, and the auditor-authored PDF report(s) under `audits/` — is licensed under the **PolyForm Noncommercial License 1.0.0**. This includes (without limitation) all source under `src/`, `test/`, `script/`; all documentation under `docs/`, `readme/`, and the root `README.md`; the `audits/README.md` index file; and the top-level configuration files (`foundry.toml`, `package.json`, `package-lock.json`, `.forgefmt.toml`, `.gitignore`, `.gitmodules`, `.env.example`). The full license text is in [LICENSE](./LICENSE).

Audit report PDFs under `audits/` are authored by their respective auditors; copyright remains with those auditors and redistribution is governed by the underlying audit engagement — see [`audits/README.md`](./audits/README.md).

This license permits use, modification, and redistribution **for any non-commercial purpose** (personal study, hobby projects, academic research, public-benefit work, government use). Commercial use is **not** permitted under this license — please contact Working Ants Inc. for a commercial license.

> Required Notice: Copyright 2025 Working Ants Inc. (Panama)

Anyone redistributing this software, in source or modified form, **must propagate the line above verbatim** along with a copy of `LICENSE` (or the URL https://polyformproject.org/licenses/noncommercial/1.0.0).

### Third-party components

The repository bundles several third-party libraries under their own permissive licenses (MIT, Apache-2.0, BSD-3-Clause). Those licenses are unchanged and continue to apply to the corresponding files. Full attribution is in [NOTICES.md](./NOTICES.md):

| Component | Path | License |
|---|---|---|
| OpenZeppelin Contracts | `lib/openzeppelin-contracts/` | MIT |
| OpenZeppelin Contracts Upgradeable | `lib/openzeppelin-contracts-upgradeable/` | MIT |
| Solady | `lib/solady/` | MIT |
| Forge Standard Library | `lib/forge-std/` | MIT OR Apache-2.0 |
| Compound Timelock | `vendor/compound-timelock/` | BSD-3-Clause (with one MIT-derived file — see [`vendor/compound-timelock/LICENSE`](./vendor/compound-timelock/LICENSE)) |

### Note on "open source"

PolyForm Noncommercial 1.0.0 is a **source-available** license, not an OSI-approved open source license (OSI Open Source Definition §6 forbids restrictions on field of endeavor, including commercial use). Use of "open source" terminology to describe this project should be avoided in contexts where OSI compliance matters.
