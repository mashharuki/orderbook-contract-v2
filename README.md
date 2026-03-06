# Sera Orderbook Contract (v2)

This repository contains **Solidity + Foundry** based order book matching contracts with vault custody, EIP-712 signatures, and dual-authorization withdrawals.

**Core Contracts:**
- **`Sera.sol`**: Core order book logic with EIP-712 signed order matching, vault custody, and dual-authorization withdrawals
- **`SeraAdmin.sol`**: Abstract admin base (treasury, whitelist, slippage sharing, pause, rescue)
- **`SeraLib.sol`**: Shared structs (`Order`, `MatchData`, `WithdrawIntent`), typehashes, and pure math functions
- **`SeraBase.sol`**: Abstract base contract for execution wrappers (Access Control + Pause Modifier + cached EXECUTOR_ROLE)
- **`SeraBatcher.sol`**: Unified batch wrapper — best-effort (`batchMatchOrders`) + fill-or-kill (`batchMatchOrdersAtomic`) + mixed mode (`batchMatchMixed`)
- **`SeraSOR.sol`**: Smart Order Router for multi-leg atomic route matching with transient balance optimization
- **`Vault.sol`**: Asset custody with per-user balances, blacklist controls, and ledger transfers
- **`interface/IVault.sol`**: Vault interface definition

**Key Features:**
- ✅ **Intent-Based Matching**: Orders are signed off-chain and matched on-chain (Gas efficient, no cancellation fees)
- ✅ **Vault Custody**: Funds are locked in `Vault.sol` ensuring solvency before execution
- ✅ **EIP-712 Signatures**: Secure typed data signing for orders and withdrawals
- ✅ **Dual-Authorization Withdrawals**:
  - **Delayed**: User-initiated via `emergencyWithdraw()`, 7200 blocks (~24h) delay with 14400 blocks (~48h) expiration
  - **Instant**: Dual-signature (`executeInstantWithdrawDualSig`) with user + executor EIP-712 signatures
- ✅ **Smart Order Routing (SOR)**: Multi-leg atomic routing via `SeraSOR.executeRoute()` with route binding (`routeHash`), single taker signature, and transient balance optimization
- ✅ **Dynamic Fee Structure**: Per-order configurable `feeBps` (uint48) + configurable slippage sharing via `SlippageShare` struct (maker/taker/protocol split)
- ✅ **Ghost Liquidity Prevention**: Vault balance checked on every match
- ✅ **Frozen User Policy**: Compromised accounts can be frozen (stops trading/deposits) but CAN withdraw
- ✅ **Partial Fills**: On-chain tracking of filled amounts for order hashes

---

## Modular Documentation Index
For detailed documentation on integrations, architecture, and deployment, see our comprehensive guides in the `readme/` folder:

1. **[Architecture Overview](readme/architecture.md)** — High-level integration diagrams for integration pairings, wrapper routing, and structural execution.
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
│   ├── SeraDeployVerify.t.sol # Deployment verification
│   ├── SeraBlacklist.t.sol   # Freeze/Blacklist tests
│   ├── SeraCoverageExtras.t.sol # Additional coverage tests
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
- **Order Struct Refactor**: `Order` now uses packed `uint48` for `expiration` and `feeBps`, includes `routeHash` for SOR binding and `uuid` for replay protection (removed `salt`/`createdAt`)
- **Slippage Sharing**: Replaced `slippageCaptureBps` with `SlippageShare` struct (`makerShareBps`, `takerShareBps`, `protocolShareBps`, `totalBps`) for configurable profit splits
- **Withdrawal System**: Dual-path withdrawals with 7200-block delay (24h) + 14400-block expiration (48h) for emergency path, or instant dual-signature path

### Security

- **Permit Front-run Protection**: `depositFundWithPermit` checks existing allowance before calling permit to avoid DoS
- **Ghost Liquidity Prevention**: Vault balance checked on every match via `_validateMakerOrder`
- **Route Binding**: SOR orders bound to specific `routeHash` preventing subset/reorder attacks
- **Price Bounds**: `InvalidCostAmount` and `TokenMismatch` assertions in `SeraLib._executionValues`

### Gas Optimizations

- Cached `EXECUTOR_ROLE` as immutable in `SeraBase.sol` (~2100 gas/call)
- Cached hot calldata fields in `_settleRoutedLegInternal`
- `unchecked` loop increments system-wide
- Fail-fast validation in `_validateOrderCommon`
- Cached `trackedBalance` in `Vault.sol` to avoid double SLOADs
- `creditLedger` for safe ledger credits without re-approval

### Cleanup

- Removed deprecated `SeraLens`, `SeraMulticall`, and `Timelock` contracts
- Removed unused Compound remapping/submodule references
