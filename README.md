# Sera Orderbook Contract (v2)

This repository contains **Solidity + Foundry** based order book matching contracts with vault custody, EIP-712 signatures, and dual-authorization withdrawals.

**Core Contracts:**
- **`Sera.sol`**: Core order book logic with EIP-712 signed order matching, vault custody, and dual-authorization withdrawals
- **`SeraAdmin.sol`**: Abstract admin base (treasury, whitelist, slippage sharing, pause, rescue)
- **`SeraLib.sol`**: Shared structs (`Order`, `MatchData`, `WithdrawIntent`), typehashes, and pure math functions
- **`SeraBase.sol`**: Abstract base contract for execution wrappers (Access Control + Pause Modifier + cached EXECUTOR_ROLE)
- **`SeraBatcher.sol`**: Unified batch wrapper — best-effort (`batchMatchOrders`) + fill-or-kill (`batchMatchOrdersAtomic`) + mixed mode with SOR intent support (`batchMatchMixed`). References both `Sera` and `SeraSOR`.
- **`SeraSOR.sol`**: Smart Order Router for multi-leg atomic route matching with transient balance optimization
- **`Vault.sol`**: Asset custody with per-user balances, blacklist controls, and ledger transfers
- **`interface/IVault.sol`**: Vault interface definition

**Key Features:**
- ✅ **Intent-Based Matching**: Orders are signed off-chain and matched on-chain (gas efficient, no cancellation fees)
- ✅ **Vault Custody**: Funds are locked in `Vault.sol` ensuring solvency before execution
- ✅ **EIP-712 Signatures**: Secure typed data signing for orders and withdrawals
- ✅ **Dual-Authorization Withdrawals**:
  - **Delayed**: User-initiated via `emergencyWithdraw()`, 7200 blocks (~24h) delay with 14400 blocks (~48h) expiration
  - **Instant**: Dual-signature (`executeInstantWithdrawDualSig`) with user + executor EIP-712 signatures
- ✅ **Smart Order Routing (SOR)**: Multi-leg atomic routing via `SeraSOR.executeIntent()` with intent-based signing. The taker signs an `IntentParams` struct covering `(inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)`. The executor constructs optimal route legs freely. Features include transient balance optimization (via `uniqueTokenCount`), signed wallet funding via `initialDepositAmount`, enforced output destination via signed `recipient`, and strict `TransientBalanceNotZero` enforcement for intermediate balances.
- ✅ **Dynamic Fee Structure**: Per-order configurable `feeBps` (uint48) + configurable slippage sharing via `SlippageShare` struct (maker/taker/protocol split)
- ✅ **Ghost Liquidity Prevention**: Vault balance checked on every match
- ✅ **Frozen User Policy**: Compromised accounts can be frozen (stops trading/deposits) but CAN withdraw
- ✅ **Partial Fills**: On-chain tracking of filled amounts for order hashes

---

## Modular Documentation Index
For detailed documentation on integrations, architecture, and deployment, see our comprehensive guides in the `readme/` folder:

1. **[Architecture Overview](readme/architecture.md)** — High-level integration diagrams for Web2/Web3 pairings, wrapper routing, and structural execution.
2. **[Integration Guide](readme/integration_guide.md)** — Step-by-step documentation for API developers looking to craft EIP-712 deposits, orders, routes, and signature payloads. Includes full standard structures.
3. **[Security Overview](readme/security.md)** — Documentation covering non-custodial extraction boundaries, blacklisting limitations, Reentrancy handling, and ghost liquidity.
4. **[Deployment Guide](readme/deployment_guide.md)** — Standard operating procedures for testing locally and initializing live Web3 networks (testnet/mainnet).
5. **[Archived Design Specs](readme/design/)** — Older architectural drafts related to gas optimizations, the SOR plan, and one-signature 7702 transactions without vault staging.

---

## Directory Structure
```
orderbook-contract-v2/
├── src/
│   ├── Sera.sol              # Core orderbook (matching + settlement + withdrawals)
│   ├── SeraAdmin.sol         # Abstract admin base (treasury, whitelist, slippage, pause, rescue)
│   ├── SeraLib.sol           # Shared structs (Order, MatchData, WithdrawIntent), typehashes, pure math
│   ├── SeraBase.sol          # Abstract base for wrappers (cached EXECUTOR_ROLE)
│   ├── SeraBatcher.sol       # Unified batch execution wrapper (best-effort + FOK + mixed)
│   ├── SeraSOR.sol           # Smart Order Router (multi-leg atomic routing with transient balances)
│   ├── Vault.sol             # Asset custody contract with ledger transfers
│   ├── interface/
│   │   └── IVault.sol        # Vault interface
│   └── mock/
│       └── MockStableCoin.sol # Testing ERC20 token
├── test/
│   ├── TestHelper.sol
│   ├── Sera.t.sol
│   ├── SeraBatcher.t.sol
│   ├── SeraRoute.t.sol
│   ├── SeraFuzz.t.sol
│   ├── SeraInvariant.t.sol
│   ├── SeraAuditCoverage.t.sol
│   ├── SeraCoverageExtras.t.sol
│   ├── SeraSOR_NonRigid.t.sol      # Core SOR sentinel & routing
│   ├── SeraSOR_AttackVector.t.sol   # Security & attack vectors
│   ├── SeraSOR_Extreme.t.sol        # Extreme spread, fees & dust
│   ├── SeraSOR_EdgeCase.t.sol       # Edge cases & emergency controls
│   ├── SeraSOR_Precision.t.sol      # Precision & arithmetic
│   ├── SeraSOR_AdvancedFuzz.t.sol   # Fuzz tests
│   ├── SeraSOR_Topology.t.sol       # Extreme topologies
│   ├── SeraSOR_Settlement.t.sol     # Settlement optimization
│   ├── SeraSOR_SettlementStress.t.sol # Settlement stress tests
│   ├── SeraSOR_Positive_Slippage.t.sol # Positive slippage PoC
│   └── summary.md                  # Detailed test audit summary
├── script/
│   ├── Deploy.s.sol          # Production deployment script
│   ├── DeployTestnet.s.sol   # Testnet deployment script (with mock tokens)
│   └── DeploySepolia.s.sol   # Sepolia deployment script with verification
├── readme/                   # Detailed modular documentation
│   ├── architecture.md       # Integration diagrams
│   ├── integration_guide.md  # API Order flows
│   ├── security.md           # Guard rails and Governance
│   ├── deployment_guide.md   # Setup procedures
│   └── design/               # Legacy point-in-time plans
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

---

## Documentation

All documentation and diagrams have been moved to the `readme/` folder. For integration guidance, architecture outlines, or API models, reference the Modular Documentation Index above.

---

## Recent Changes & Optimizations

### Architecture

- **Solady Integration**: Replaced OpenZeppelin's `EIP712` and `ECDSA` with Solady's gas-optimized alternatives
- **Order Struct Refactor**: `Order` now uses packed `uint48` for `expiration` and `feeBps`, includes `initialDepositAmount` for signed SOR funding control, and `uuid` for replay protection (removed `salt`/`createdAt`/`routeHash`)
- **Slippage Sharing**: Replaced `slippageCaptureBps` with `SlippageShare` struct (`makerShareBps`, `takerShareBps`, `protocolShareBps`, `totalBps`) for configurable profit splits
- **Withdrawal System**: Dual-path withdrawals with 7200-block delay (24h) + 14400-block expiration (48h) for emergency path, or instant dual-signature path
- **SOR Intent-Based Architecture**: The SOR uses an intent model — the taker signs an `IntentParams` struct `(inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)` once, and the executor freely constructs optimal route legs at execution time. The `recipient` and `initialDepositAmount` are cryptographically committed to prevent output hijacking and unauthorized wallet pulls. This fixes TOCTOU issues with the old `routeHash` route-binding model. Final-leg positive slippage follows the configured slippage split. Any leftover intermediate transient balances trigger a `TransientBalanceNotZero` revert, enforcing strict fund conservation.

### Security

- **Permit Front-run Protection**: `depositFundWithPermit` checks existing allowance before calling permit to avoid DoS
- **Ghost Liquidity Prevention**: Vault balance checked on every match via `_validateMakerOrder`
- **SOR Intent Replay Protection**: Per-user UUID nonce mapping (`isIntentUuidUsed[user][uuid]`) prevents intent replay without global nonce contention
- **SOR Envelope Guards**: On-chain `maxInputAmount` and `minOutputAmount` guards signed by the taker cap total spending and floor total output across all route legs
- **Signed SOR Recipient (Diamond-Safe)**: `recipient` is signed inside the intent, and every terminal leg's `order0.recipient` is enforced to match. This prevents output hijacking in both linear and split/diamond topologies.
- **Signed SOR Wallet Funding**: `initialDepositAmount` is signed inside the intent so executors cannot modify the wallet pull amount at execution time. The exact amount signed is the exact amount pulled.
- **Price Bounds**: `InvalidCostAmount` and `TokenMismatch` assertions in `SeraLib._executionValues`
- **`creditLedger` Zero-Address Guard**: Added `user != address(0)` sanity check in `Vault.creditLedger()` to prevent accidentally burning vault balance to the zero address
- **EIP-712 Canonical Array Encoding**: Fixed `executeInstantWithdrawDualSig` to hash `address[]` tokens as 32-byte-padded words (per EIP-712 spec) instead of `abi.encodePacked` 20-byte packing, ensuring full compatibility with standard wallets and SDKs

### Gas Optimizations

- **SOR Gas Efficiency**: `SeraSOR` now allocates transient memory efficiently through a `uniqueTokenCount` hint passed by the off-chain matching engine, drastically reducing MSTORE memory expansion penalties during multi-leg route execution
- Cached `EXECUTOR_ROLE` as immutable in `SeraBase.sol` (~2100 gas/call)
- Cached hot calldata fields in `_settleRoutedLegInternal`
- `unchecked` loop increments system-wide
- Fail-fast validation in `_validateOrderCommon`
- Cached `trackedBalance` in `Vault.sol` to avoid double SLOADs
- `creditLedger` now relies on a documented push-then-credit invariant, removing the old surplus check and avoiding future TOCTOU-style multi-trader races

### Cleanup

- Removed deprecated `SeraLens`, `SeraMulticall`, and `Timelock` contracts
- Removed unused Compound remapping/submodule references
