# Sera Web2/Web3 Integration Architecture

Sera is explicitly designed to be paired with an off-chain Web2 matching engine and an automated Executor/Relayer. This hybrid architecture extracts the high-performance order matching capabilities found in Centralized Exchanges (CEX) while relying on non-custodial cryptographic settlement on-chain.

## High-Level Execution Flow

```mermaid
sequenceDiagram
    participant User as User Wallet
    participant Frontend as Web Application
    participant API as Web2 Matching Engine
    participant Relayer as On-Chain Executor
    participant Sera as Sera Smart Contracts

    User->>Frontend: Request Trade / Action
    Frontend->>API: Fetch Best Route & Pricing
    API-->>Frontend: Return EIP-712 Payload
    Frontend->>User: Prompt Wallet Signature
    User-->>Frontend: Sign EIP-712 SOR Order
    Frontend->>API: Submit Signed SOR Order
    API->>API: Match Engine Engine Crossing
    API->>Relayer: Enqueue Matched Orders
    Relayer->>Sera: Submit Tx (matchOrders / batch / swap)
    Sera-->>Relayer: Settle & Emit Events
    API-->>Frontend: Confirm On-Chain Settlement
```

## Contract Execution Environments
The Sera protocol utilizes a modular wrapper architecture. Depending on the action identified by the Web2 API, the relayer submits to different execution wrappers, all of which funnel down into the core engine.

```mermaid
graph TD
    API[Web2 API / Relayer] -->|1:1 Atomic Match| Sera(Sera.sol Engine)
    API -->|Best-Effort Batch| SeraBatcher(SeraBatcher.sol)
    API -->|FOK Atomic Batch| SeraBatcher
    API -->|Mixed Batch + SOR Executions| SeraBatcher
    API -->|Multi-Leg Route| SeraSOR(SeraSOR.sol)
    API -->|Direct EOA Swap| SeraSOR(SeraSOR.sol: executeIntent - SOR entry point)

    SeraBatcher -->|Executor Role Call| Sera
    SeraBatcher -->|SOR Execution Delegation| SeraSOR
    SeraSOR -->|Executor Role Call| Sera
    SeraSOR -->|Router Role Call| Sera(settleRoutedLeg)

    Sera --> Vault[(Vault.sol Custody)]
```

### Implicit Vault Rebates & Pull Optimization
When trades execute with a physiological spread (i.e. Taker provides more than Maker expects), the Sera engine internally computes the split (e.g., Maker vs. Taker vs. Protocol). Critically, `Sera.sol` enforces these splits via **implicit mathematical rebates** instead of explicit token pushes.

For SOR (routed) settlement, this is further optimized:

1. **First-leg vault pull optimization:** `_settleRoutedLegInternal` computes `neededFromTaker = makerReceives + protocolTake0` and `transientPhysical = effectiveMatchAmount0 - takerVaultPull` *before* vault interaction, then pulls only the deficit from the vault. The taker's spread share (`spreadToTaker0`) remains in the vault implicitly — never transferred out and round-tripped back. If the transient physical tokens alone exceed the cost, any surplus is returned to the taker's vault via `safeTransfer` + `creditLedger`. This saves ~7k gas per vault-pulled leg.

2. **Sentinel surplus safety net:** For intermediate sentinel legs (tokens held in Sera from a previous hop), any non-zero surplus (`transientPhysical - neededFromTaker`) is returned to the taker's vault via `safeTransfer` + `creditLedger`. In production, the Matching Engine pre-calculates exact `matchAmount1` values to ensure zero intermediate spread, making this block effectively dead code — but it prevents funds from being stranded in Sera.

3. **ME-centric invariant:** The off-chain Matching Engine guarantees that for every sentinel leg, `executionValue1 == resolvedSentinelAmount` (zero spread). Any accidental mismatch in a multi-leg chain ultimately triggers a `TransientBalanceNotZero` revert at route completion, enforcing strict conservation of funds.

## Off-Chain Requirements
1. **Nonce & UUID Management:** The smart contract strictly enforces `isUuidExecuted[user][uuid]` for instant withdrawals, `isIntentUuidUsed[user][uuid]` for SOR executions, and `filledAmount` trackers for trades. Your off-chain system should deterministically construct UUIDs to prevent users from accidentally signing the same SOR orders via frontend retries.
2. **Execution Timing:** All limits have standard `expiration` timestamps. Relayers must ensure they submit batches to the mempool comfortably prior to this expiry window.
3. **SOR Match Calibration:** For multi-hop routes, the ME must calculate each intermediate leg's `matchAmount1` such that `executionValue1 == resolvedSentinelAmount` for zero-surplus settlement. Failure to calibrate correctly will cause the route to revert with `TransientBalanceNotZero`.
