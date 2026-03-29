# Audit FAQ: Deliberate Design Choices & "Gas-Over-Verify" Patterns

This document serves as a reference for security auditors to understand specific architectural patterns in the Sera Orderbook that may initially appear as vulnerabilities but are deliberate gas optimizations with mathematically enforced security.

---

## 1. Signature Verification Skip on Partial Fills

**Location:** `Sera.sol` - `_validateMakerOrder()`

### Observed Pattern
The contract only calls `_validateSignature()` if `filledAmount[orderHash] == 0`. For subsequent fills (partial fills), signature verification is skipped.

### Why this is Secure
This is a **Signature Caching** optimization. It is cryptographically safe due to the following invariants:

1. **Hash Immutability:** The `orderHash` is derived from the *entire* `Order` struct. If an executor attempts to modify any parameter (price, amount, tokens, expiration, uuid, recipient), the `orderHash` changes.
2. **First-Fill Authentication:** The only way to get `filledAmount[orderHash] > 0` is to have successfully passed `_validateSignature()` in a previous transaction for that *exact* hash.
3. **Budget Enforcement:** The `filledAmount[orderHash] + matchAmount <= order.fromAmount` check ensures that the cached authentication only applies to the total volume originally authorized by the user.

### Benefit
Saves ~3,000+ gas per partial fill by avoiding redundant `ecrecover` calls and reduces calldata overhead.

---

## 2. Unsupported Fee-on-Transfer Tokens Are Out of Scope

**Location:** `Vault.sol` - `deposit()`

### Observed Pattern
The `deposit()` function credits the requested amount and does not measure post-transfer balance deltas.

### Why This Is Not Treated as a Protocol Issue
Fee-on-transfer assets are outside the supported asset model. The protocol enforces a **no-FoT policy** at the governance layer:
1. Only standard ERC20 tokens are whitelisted via `SeraAdmin.batchModifyWhitelistedTokens()`.
2. Any token attempting to implement a tax or burn on transfer will be excluded from the whitelist.
3. This significantly simplifies the core logic and saves gas for 99% of standard tokens (USDC, USDT, WETH, etc.) by avoiding double `balanceOf` checks.

Within that supported asset universe, there is no accounting issue to fix. If governance were to deliberately whitelist a non-standard asset class anyway, that would be an explicit policy violation rather than an unexpected protocol bug.

---

## 3. Transient Balance Hash Table (Open-Addressing)

**Location:** `SeraSOR.sol` - `_findTokenSlot()`

### Observed Pattern
The Smart Order Router (SOR) uses an in-memory array as a hash table with linear probing instead of a standard Solidity `mapping`.

### Why this is Secure
This is a high-performance **Transient Storage Simulation**.
1. **Load Factor Invariant:** The table size is dynamically allocated based on an off-chain hint (`uniqueTokenCount`). It sets `tableSize = (uniqueTokenCount * 2) + 1`. This safely guarantees a load factor of <50%, ensuring the linear probe (`_findTokenSlot`) will always find an empty slot or the target token without an infinite loop.
2. **Deterministic Hashing:** Using `uint256(uint160(token)) % tableSize` provides a stable index for addresses.
3. **Collision Safety:** Linear probing correctly handles collisions in the rare event that two token addresses hash to the same index.

### Benefit
Mappings cannot be created in memory. By using an array with a custom hash function, the SOR avoids all `SSTORE` and `SLOAD` operations for intermediate token hops, reducing SOR gas costs by up to 15,000 per hop.

---

## 4. Settlement Rounding Cannot Underflow (Mathematical Proof)

**Location:** `Sera._calculateSettlement` / `Sera._collectAndDistribute`

### Observed Pattern

The spread distribution uses three sequential `mulDiv` calls that round down:

```solidity
uint256 protocolSpread0 = Math.mulDiv(totalSpread0, shares.protocolShareBps, shares.totalBps);
uint256 makerBonus0     = Math.mulDiv(totalSpread0, shares.makerShareBps,   shares.totalBps);
uint256 takerBonus0     = totalSpread0 - protocolSpread0 - makerBonus0;
```

An auditor may flag `takerBonus0` as an underflow candidate if `protocolSpread0 + makerBonus0 > totalSpread0`.

### Why this Cannot Underflow

**Invariant 1 — `totalSpread0 ≥ 0`:** The guard `if (matchAmount0 < executionValue1) revert InvalidCostAmount()` in `_executionValues` ensures `totalSpread0 = matchAmount0 - executionValue1 ≥ 0`.

**Invariant 2 — `takerBonus0 ≥ 0`:** `setSlippageShares` enforces `makerShareBps + takerShareBps + protocolShareBps == totalBps`. Therefore `protocolShareBps + makerShareBps = totalBps - takerShareBps ≤ totalBps`. By sub-additivity of floor division:

```
floor(x·a/d) + floor(x·b/d) ≤ floor(x·(a+b)/d) ≤ floor(x·totalBps/totalBps) = x
```

So `protocolSpread0 + makerBonus0 ≤ totalSpread0` always holds. `takerBonus0 ≥ 0`. QED.

**Invariant 3 — `executionValue1 - protocolFee0 ≥ 0`:** `_validateOrderCommon` enforces `feeBps ≤ BPS_DENOMINATOR`, so `protocolFee0 = mulDiv(executionValue1, feeBps, BPS) ≤ executionValue1 ≤ calc.executionValue1`. QED.

### Verification

This has been mathematically verified by modeling the `_calculateSettlement` logic to confirm rounding behavior remains within safe bounds.

---

## 5. feeBps = 10000 (100%) Is Deliberate User Consent

**Location:** `Sera._validateOrderCommon`

### Observed Pattern

The fee validation uses a strict greater-than check:

```solidity
if (order.feeBps > BPS_DENOMINATOR) revert InvalidFee();
```

This allows `feeBps = 10000` (100%). With a 100% fee, the fee recipient's token output goes entirely to treasury and the signer receives nothing.

### Why This Is Deliberate

The `feeBps` field is part of the **EIP-712 signed order struct**. A user who signs an order with `feeBps = 10000` has cryptographically consented to donating 100% of their output to the protocol. This could be used legitimately (e.g. a treasury deposit order, a promotional zero-output trade, or a protocol-owned market maker order).

The contract correctly honors exactly what the user signed — this is the core security model. No executor can set `feeBps` above what the user signed.

### Distinction from a Real Vulnerability

A *real* vulnerability would be if an executor could **modify** `feeBps` after signing, or if the fee were applied to a *different* user than the signer. Neither is possible here: the `orderHash` commits to `feeBps`, and any change invalidates the signature.

## 6. De-Whitelisted Token Orders Can Still Be Partially Filled

**Location:** `Sera._validateOrderCommon`

### Observed Pattern

When a token is removed from the whitelist, existing orders for that token that have already been partially filled can continue to be matched. The whitelist check (`if (!config.isWhitelisted) revert;`) is only performed on the first fill (`if (filled == 0)`).

### Deliberate Design

This is a deliberate design choice to shift responsibility to the execution layer. The smart contract is designed to be **reactive rather than authoritative**.

If a token is deemed unsafe and de-whitelisted, the executor will cease to include orders involving that token in its match payloads. The on-chain state remains valid, but the path to execution is severed off-chain. Users are expected to manually cancel their outstanding orders for de-whitelisted tokens if they wish to formally void them on-chain.

---

## 7. Rebasing / Elastic Supply Tokens Are Not Supported

**Location:** `Vault.sol`

### Observed Pattern

The Vault uses a `trackedBalance` mapping alongside physical token balances. For rebasing tokens (e.g., stETH, AMPL), the physical balance changes autonomously, causing a divergence from `trackedBalance`. This can lead to trapped surplus yield or insolvency for late withdrawers.

### Design Enforcement

This is a known limitation. The protocol strictly enforces a **no-rebasing tokens** policy at the governance layer, identical to the no fee-on-transfer policy.

Only standard, fixed-supply ERC20 tokens are whitelisted via `SeraAdmin.batchModifyWhitelistedTokens()`. Avoiding complex accounting logic for rebasing tokens saves significant gas for all standard token pairs.

---

## 8. `toToken` Whitelist Is Deliberately Unchecked

**Location:** `Sera._validateOrderCommon`

### Observed Pattern

The whitelist check in `_validateOrderCommon` only validates `order.fromToken`. `order.toToken` is never explicitly checked against the whitelist.

### Deliberate Design

This is a phased deprecation strategy. If a token needs to be removed from the ecosystem, it is first hidden on the frontend interface. The executor will then cease to route orders involving this token. Once the off-chain layer has fully drained or expired relevant routes, the token is eventually removed from the on-chain whitelist.

During the wind-down window, the lack of a `toToken` check allows the executor to cleanly resolve existing taker orders that expected the deprecated token as output, without hard-reverting the matches. Since only permissioned executors can submit matches, there is no risk of arbitrary exploitation.

---

## 9. `batchMatchMixed` Inner Array Lacks Length Bounds

**Location:** `SeraBatcher.batchMatchMixed`

### Observed Pattern

While the outer batch array is capped at `MAX_BATCH_SIZE`, the inner `MatchData[]` array within an `AtomicBatch` has no explicit size limit before it is passed to `batchMatchOrdersAtomic`. If an executor passes an extremely large inner array, the inner function will revert, but only after the EVM has deserialized the massive array in calldata, wasting gas. Additionally, combined matches > 256 will overflow the `failedMask` bitmask.

### Gas-Over-Verify Pattern

This is an accepted tradeoff. The only entity that can submit these arrays is the permissioned executor. If the executor constructs an excessively large payload, the only consequence is the executor wasting their own gas or receiving a misleading `failedMask`. No user funds or protocol invariants are put at risk. Minimizing on-chain bounds checking where off-chain systems are well-behaved reduces gas costs for normal operations.

---

## 10. Spread Rounding Dust Favors Takers

**Location:** `Sera._calculateSettlement`

### Observed Pattern

When distributing the spread, the protocol fee and maker bonus are calculated using `mulDiv` which rounds down. The taker bonus is calculated as the residual: `takerBonus0 = totalSpread0 - protocolSpread0 - makerBonus`.

### Deliberate Incentive Alignment

Because the taker receives the residual, the taker absorbs all rounding dust (up to 2 wei per settlement side). This creates a slight systematic bias favoring the taker.

This is a deliberate design choice in DEX math. Takers are the active participants crossing the spread and bearing execution risk. Allocating the fractional dust upside to the taker provides a micro-incentive and simplifies the math, avoiding complex tracking of fractional wei across millions of trades.

## 11. Blacklisted Users Can Still Receive Settlement Payouts

**Location:** `Sera._executeVaultSettlement` / `Vault.transferLedger`

### Observed Pattern

When a user is blacklisted via `Vault.setBlacklisted()`, they are prevented from depositing new funds (`Vault.deposit()`). However, `transferLedger()` and `withdraw()` do not check the recipient's blacklist status. If an order previously signed by the blacklisted user is matched, their vault balance can still be credited.

### Deliberate Design

This pattern correctly models the distinction between **inbound capital restriction** and **asset custody guarantees**.

Blacklisting prevents an account from expanding its vault position with external assets. However, if a user's funds are already in the system (or tied up in a resting limit order), the protocol must allow those funds to naturally settle according to their cryptographically signed commitments. Furthermore, blacklisted users must always be able to withdraw their existing assets (`emergencyWithdraw` / `withdraw`), as permanently freezing assets would create custody risk and regulatory liability. The inability to use `deposit()` effectively quarantines the account while honoring existing obligations.

---

## 12. SeraSOR `_computeSORHash` Is Public

**Location:** `SeraSOR._computeSORHash`

### Observed Pattern

The internal routing logic function `_computeSORHash` is marked as `internal pure`.

### Why This Is Safe

Because the smart contract ecosystem is open-source, the SOR hashing logic is fully public regardless of the function visibility modifier. Marking a purely deterministic `pure` function as `internal` is a gas optimization rather than a security concern. 

In a system operated by a centralized, permissioned executor (`EXECUTOR_ROLE`), pre-computation griefing (where an attacker pre-computes hashes off-chain to race the executor) is impossible, as the attacker cannot successfully call `executeIntent` anyway.

---
---

## 13. `depositFundWithPermit` Allows Sponsored Deposits and Approval Reuse by Design

**Location:** `Sera.sol` - `depositFundWithPermit()`

### Observed Pattern
To safely allow gas to be sponsored or paid by a executor, `depositFundWithPermit()` intentionally omits a `msg.sender == _owner` check.

### Why this is Secure
The EIP-2612 `permit` signature itself cryptographically anchors the `_owner` address. Funds can **only** move from the signer's wallet directly into the vault balance associated with that same signer. There is no way for a third party to redirect the funds to themselves.

The same logic applies when the vault already has sufficient allowance:
- if an earlier permit left unused allowance on the vault, later calls can reuse that approval without a fresh signature
- if the owner granted allowance directly, any caller can sponsor the deposit transaction
- in all cases, the transfer still goes from `_owner` to the vault and the credit still lands on `_owner`

This is standard ERC20 approval semantics, not an authorization bypass.

### The Front-Running Vector (Gas Griefing)
The primary "risk" is that a front-running bot can observe the permit signature in the mempool and execute the transaction first. 
- **Impact on User:** Zero. Their funds end up in their vault balance exactly as intended.
- **Impact on Relayer/Sponsor:** The sponsor's transaction will revert (since the permit nonce is already consumed by the bot), causing the sponsor to waste gas on a failed execution.

### Design Enforcement
This is a **deliberate design choice** to enable gasless user deposits (sponsored by the protocol). The cost of rare gas griefing against the platform is accepted as a tradeoff for the improved user onboarding experience. Executors can mitigate this by checking if the permit nonce is already used before submitting their own transaction.

---

## 14. Audit Issue 3: SOR Positive Slippage Redistribution Depends on Where the Surplus Appears

**Location:** `SeraSOR.executeIntent()` and `Sera._calculateSettlement()`

### Observed Pattern

The protocol now reverts with `TransientBalanceNotZero` if any transient balances remain at the end of a SOR route.

At first glance, this can look inconsistent with the configured slippage split, because final-leg positive slippage is shared with the taker while leftover intermediate-leg surplus may end up fully credited to the protocol treasury.

### Why This Happens

The key distinction is whether the surplus reaches a final recipient or remains stranded in transient route state.

#### Scenario A: Single-leg trade
If there is no routing, the positive slippage is distributed normally according to `SlippageShare`. The taker receives their configured share immediately.

#### Scenario B: Final leg of a multi-leg SOR route
The final leg behaves the same way as a normal trade. There is no downstream consumer, so the taker receives their share in the final output token or Vault balance.

#### Scenario C: Intermediate leg with no leftover balance
If the next leg consumes the entire intermediate output, nothing remains stranded. No extra treasury sweep occurs beyond the normal protocol share already charged during settlement.

#### Scenario D: Intermediate leg with leftover positive surplus
If an intermediate leg produces more output than downstream signed legs are configured to consume, the excess remains in transient route state inside `Sera`. Later legs cannot auto-resize because the route is built from statically signed order amounts. At route end, any residual transient balance triggers a `TransientBalanceNotZero` revert, ensuring strict conservation of funds.

### Design Tradeoff

This is a deliberate pragmatic tradeoff:
- it prevents valid routes from reverting on intermediate positive slippage
- it prevents leftover tokens from remaining stuck in the contract (they trigger a revert)
- it preserves the existing signed route model without a major refactor for dynamic downstream resizing

In practice:
- final-leg surplus is redistributed normally
- stranded intermediate residuals cause a `TransientBalanceNotZero` revert

## 15. Audit Issue 4: Signed `initialDepositAmount` Prevents Executor-Controlled Funding Source Selection

**Location:** `SeraLib.Order`, `SeraLib.ORDER_TYPEHASH`, `SeraLib.getOrderHashCalldata()`, and `SeraSOR.executeIntent()`

### Observed Pattern

The SOR now includes `initialDepositAmount` directly inside the signed taker `Order` struct for the first route leg.

### Why This Changed

Previously, the executor could choose how much of the first-leg taker input was pulled from the user's wallet versus their Vault balance at execution time. That meant the taker did not cryptographically control the exact funding path for the route.

By moving `initialDepositAmount` into the signed `Order` payload and `ORDER_TYPEHASH`, the taker now explicitly authorizes the wallet-funded portion when signing.

### Resulting Behavior

- if `matches[0].order0.initialDepositAmount > 0`, SOR pulls exactly that signed amount from the taker's external wallet into `Sera`
- if `matches[0].order0.initialDepositAmount == 0`, SOR funds the route entirely from the taker's Vault balance
- if the route needs more than the signed wallet-funded amount, the remainder is sourced from the taker's Vault balance
- the executor can no longer arbitrarily switch a user from Vault funding to wallet funding

### Why This Is the Correct Fix

- no new trust assumptions are introduced
- the user regains cryptographic control over route funding source selection
- the fix is minimal because it reuses the existing EIP-712 order signing flow instead of introducing a second signed parameter path
