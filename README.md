# Sera Orderbook Contract (v2)

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
- ✅ **Smart Order Routing (SOR)**: Multi-leg atomic routing via `SeraSOR.executeIntent()` with SOR-based signing. The taker signs an `IntentParams` (SOR parameters) struct covering `(taker, inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)`. The `taker` field cryptographically binds the signer's identity inside the EIP-712 struct, enabling EIP-1271 smart contract wallet support. The executor constructs optimal route legs freely. Features include transient balance optimization (via `uniqueTokenCount`), signed wallet funding via `initialDepositAmount`, enforced output destination via signed `recipient`, and strict `TransientBalanceNotZero` enforcement for intermediate balances.
- ✅ **Dynamic Fee Structure**: Per-order configurable `feeBps` (uint48) with expanded `BPS_DENOMINATOR = 1e14` for sub-basis-point granularity (e.g. $0.01 fee on $1M orders) + configurable slippage sharing via `SlippageShare` struct (maker/taker/protocol split)
- ✅ **Signature Caching**: First fill verifies the EIP-712 signature via `SignatureChecker` (supports both EOA `ecrecover` and EIP-1271 contract signatures); subsequent partial fills skip re-verification since the `orderHash` is immutable and already authenticated
- ✅ **Transient Reentrancy Guard**: `ReentrancyGuardTransient` on all `Sera.sol` entry points — locks use transient storage (EIP-1153), lasting only for the cross-contract execution duration
- ✅ **Ghost Liquidity Prevention**: Vault balance checked on every match
- ✅ **Frozen User Policy**: Compromised accounts can be frozen (stops trading/deposits) but CAN withdraw
- ✅ **Partial Fills**: On-chain tracking of filled amounts for order hashes
- ✅ **Token Whitelist**: Governance-controlled whitelist with per-token minimum order amounts

---

## Modular Documentation Index
For detailed documentation on integrations, architecture, and deployment, see our comprehensive guides in the `docs/` folder:

1. **[Architecture Overview](docs/architecture.md)** — High-level integration diagrams for Web2/Web3 pairings, wrapper routing, and structural execution.
2. **[Integration Guide](docs/integration_guide.md)** — Step-by-step documentation for API developers looking to craft EIP-712 deposits, orders, routes, and signature payloads. Includes full standard structures.
3. **[Security Overview](docs/security.md)** — Documentation covering non-custodial extraction boundaries, blacklisting limitations, Reentrancy handling, and ghost liquidity.
4. **[Deployment Guide](docs/deployment_guide.md)** — Standard operating procedures for testing locally and initializing live Web3 networks (testnet/mainnet).
5. **[API Server Design](docs/api_server_design.md)** — Backend technical specification for API server developers (bilingual: Chinese).
6. **[Audit FAQ](docs/audit_faq.md)** — Deliberate design choices and "gas-over-verify" patterns explained for security auditors.
7. **[Gas Report](docs/design/gas_report.md)** — Architectural impact of transient matching and route caching.

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
│   ├── SeraSOR_Settlement.t.sol        # Settlement optimization
│   ├── SeraSOR_SettlementStress.t.sol  # Settlement stress tests
│   ├── SeraSOR_Positive_Slippage.t.sol # Positive slippage PoC (stub)
│   ├── SeraSOR_Permit.t.sol            # EIP-2612 permit integration tests
│   ├── SeraSOR_DeepAudit.t.sol         # Deep audit PoC validations
│   ├── SeraSOR_CoverageGaps.t.sol      # Coverage gap tests (diamond, wallet funding)
│   ├── SeraSOR_AttackerSteal.t.sol     # Output hijacking fix validation
│   ├── SeraEIP1271.t.sol               # EIP-1271 smart contract wallet signature tests
│   ├── Sera_FullCoverage.t.sol         # Full coverage suite (51 tests)
│   ├── SeraBPS_Precision.t.sol         # BPS denominator precision & overflow tests
│   └── summary.md                     # Detailed test audit summary
├── script/
│   ├── Deploy.s.sol              # Production deployment script
│   ├── DeployTestnet.s.sol       # Testnet deployment script (with mock tokens)
│   ├── DeploySepolia.s.sol       # Sepolia deployment script with verification
│   ├── DeployAll.s.sol           # Combined deployment script
│   ├── DeployLocal.s.sol         # Local development deployment
│   └── LiveSubgraphValidation.s.sol # Live subgraph validation script
├── docs/                     # Detailed modular documentation
│   ├── architecture.md       # Integration diagrams
│   ├── integration_guide.md  # API Order flows
│   ├── security.md           # Guard rails and Governance
│   ├── deployment_guide.md   # Setup procedures
│   ├── api_server_design.md  # Backend technical specification (bilingual)
│   ├── audit_faq.md          # Deliberate design choices for auditors
│   └── design/gas_report.md  # Optimization tracking
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

### Local Subgraph Testing (E2E)
A fully automated local subgraph integration test suite is available in the `../sera-web3-layer-graph` repository. It spins up a local Graph Node, an Anvil chain, and automatically deploys these contracts to fully verify event indexing correctness.

To run the local indexing test:
```shell
cd ../sera-web3-layer-graph
make test
```

### Full Stack E2E (Relayer + Contracts + Subgraph)
To test the full pipeline including the relayer submitting transactions, subgraph indexing events, and the relayer reading indexed data back:

```shell
cd ../web3-relayer
make e2e
```

See [web3-relayer/README.md](../web3-relayer/README.md) for details.

### Coverage
```shell
forge coverage
```

---

## Documentation

All documentation and diagrams have been moved to the `docs/` folder. For integration guidance, architecture outlines, or API models, reference the Modular Documentation Index above.

---

## Recent Changes & Optimizations

### Architecture

- **Solady Integration**: Uses Solady's gas-optimized `EIP712`. Signature validation uses OpenZeppelin's `SignatureChecker` for unified EOA + EIP-1271 smart contract wallet support
- **Order Struct Refactor**: `Order` now uses packed `uint48` for `expiration` and `feeBps`, includes `initialDepositAmount` for signed SOR funding control, and `uuid` for replay protection (removed `salt`/`createdAt`/`routeHash`). `BPS_DENOMINATOR` expanded to `1e14` (from `10,000`) for sub-basis-point fee granularity while fitting within `uint48` storage.
- **Slippage Sharing**: Replaced `slippageCaptureBps` with `SlippageShare` struct (`makerShareBps`, `takerShareBps`, `protocolShareBps`, `totalBps`) for configurable profit splits
- **Withdrawal System**: Dual-path withdrawals with 7200-block delay (24h) + 14400-block expiration (48h) for emergency path, or instant dual-signature path
- **SOR-Based Architecture**: The SOR uses a signed routing model — the taker signs an `IntentParams` (SOR parameters) struct `(taker, inputToken, outputToken, maxInput, minOutput, recipient, initialDepositAmount, uuid, deadline)` once, and the executor freely constructs optimal route legs at execution time. The `taker`, `recipient`, and `initialDepositAmount` are cryptographically committed to prevent identity spoofing, output hijacking, and unauthorized wallet pulls. The `taker` field enables EIP-1271 smart contract wallet support by binding the signer's address into the signed struct (replacing the old `ecrecover`-derived identity model). This fixes TOCTOU issues with the old `routeHash` route-binding model. Final-leg positive slippage follows the configured slippage split. Any leftover intermediate transient balances trigger a `TransientBalanceNotZero` revert, enforcing strict fund conservation.

### Security

- **Permit Front-run Protection**: `depositFundWithPermit` checks existing allowance before calling permit to avoid DoS
- **Ghost Liquidity Prevention**: Vault balance checked on every match via `_validateMakerOrder`
- **SOR Replay Protection**: Per-user UUID nonce mapping (`isIntentUuidUsed[user][uuid]`) prevents SOR replay without global nonce contention
- **SOR Envelope Guards**: On-chain `maxInputAmount` and `minOutputAmount` guards signed by the taker cap total spending and floor total output across all route legs
- **Signed SOR Recipient (Diamond-Safe)**: `recipient` is signed inside the SOR parameters, and every terminal leg's `order0.recipient` is enforced to match. This prevents output hijacking in both linear and split/diamond topologies.
- **Signed SOR Wallet Funding**: `initialDepositAmount` is signed inside the SOR parameters so executors cannot modify the wallet pull amount at execution time. The exact amount signed is the exact amount pulled.
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
