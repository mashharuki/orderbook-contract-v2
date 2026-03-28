# Sera Integration Security Safeguards

This document captures the critical safeguards implemented in the Sera Orderbook v2 protocol. It is specifically meant for developers integrating with the protocol to understand where boundaries exist, and how the core handles various states of insolvency or account compromise.

## 1. Vault Roles & Governance
Sera delegates its actual token custody entirely to `Vault.sol`. The Vault is an `AccessControl` registry.
- `Sera.sol` Engine holds the `TRADER_ROLE` over the Vault, granting it `deposit`/`withdraw`/`transferLedger` execution capabilities.
- The system highly recommends `DEFAULT_ADMIN_ROLE` for both Sera and Vault to be transferred to an existing, on-chain [Compound Timelock](https://github.com/compound-finance/compound-protocol/blob/master/contracts/Timelock.sol) controlled by a multisig (e.g., Gnosis Safe). The Timelock enforces a minimum delay (e.g., 48 hours) on all admin actions, including role grants. See the [Deployment Guide](deployment_guide.md) for concrete setup steps.
- **Admin Configuration (SeraAdmin):** Functions like `setTreasury`, `setSlippageShares` (for configurable 3-way profit splits), `batchModifyWhitelistedTokens`, `pause`, and `unpause` are consolidated in `SeraAdmin.sol` (which `Sera.sol` inherits) for cleanly separated governance logic.

## 2. The Non-Custodial Guarantee
In the event that the executor ceases matching, or the platform interface goes offline permanently, user funds are never permanently locked.
- **Manual Delayed Withdrawals:** A user can query the contract directly (e.g., via Etherscan) and broadcast `emergencyWithdraw(token, amount)`. This stamps a request in `WithdrawRequest` associated with the current block.
- After `WITHDRAW_DELAY_BLOCKS` (approx. 24 hours) have ticked, the user broadcasts the exact same payload. The funds are disbursed safely to the caller. High delays prevent the executor from experiencing mid-flight race conditions against user intent logic.

## 3. Blacklisting / Identity Freeze
Compromised accounts (e.g., a hacked user wallet) can be frozen by the `DEFAULT_ADMIN_ROLE` using `Vault.setBlacklisted(user, true)`.
- Blacklisted users cannot execute `deposit()` actions.
- Any trades submitted by blacklisted users will violently revert (`UserFrozen`).
- **Safety First:** A blacklisted user *is strictly permitted* to execute Withdrawals. The protocol ensures no one can permanently deny a user access to withdrawing their underlying assets to their private key.

## 4. Ghost Liquidity & The 24h Sync Window
Because orders are signed as intents off-chain, the system must handle the case where a user signs an order and subsequently initiates an emergency withdrawal.

- **The 24h Sync Window:** The `emergencyWithdraw` function imposes a 24-hour delay. This is a critical design feature that allows the executor to monitor the blockchain, detect a user's intent to withdraw, and proactively cancel or block that user's off-chain orders before the funds are actually released.
- **On-Chain Failsafe:** As a final layer of defense (e.g., during executor downtime), the `Sera.sol` internal matching functions explicitly execute an invariant check: `vault.balanceOf(token, user) >= requiredMatchAmount`.
- **Graceful Failure:** Invalidly backed orders (those without sufficient vault balance) immediately halt and fail to match. Relying wrappers (`SeraBatcher`) can gracefully continue parsing remaining orders without dropping the entire payload.

## 5. Match Execution Integrity Limits
Because the executor determines the exact ratios crossed via limit inputs, the smart contract strictly enforces mathematical invariants to protect both users:
- **Price Bounds Check (`InvalidCostAmount`):** The engine mathematically asserts that the Taker is paying *at least* what the Maker's required exchange rate dictates, preventing relayers from intentionally granting worse execution prices.
- **Strict Token Alignments (`TokenMismatch`):** The Engine verifies identically matching `fromToken` and `toToken` properties between Order 0 and Order 1.
- **Implicit Rebate System:** When the two limits create a natural spread bonus, the engine partitions a configurable slippage share to the Protocol, the Maker, and the Taker. Critically, to protect physical vault solvency, the Protocol never *pushes* a bonus to a receiver. Instead, whoever *sent* the surplus token explicitly receives a discount applied seamlessly beneath their maximum spending limit.
- **Pull-Only Settlement (SOR):** For routed legs, `_settleRoutedLegInternal` computes `neededFromTaker = makerReceives + protocolTake0` *before* vault interaction and only withdraws that net amount. The taker's spread share (`spreadToTaker0`) implicitly stays in the vault, eliminating redundant `safeTransfer` + `creditLedger` round-trips (~7k gas saved per vault-pulled leg).

## 6. Reentrancy Guarding
ERC-777 callbacks and dangerous fallback loops are effectively sandboxed.
- `Sera.sol` guards all entry points using `ReentrancyGuardTransient`.
- Transient storage ensures that locks only last for the duration of the cross-contract execution, saving significant gas while isolating malicious token behavior.
- Wrappers like `SeraSOR.sol` enter `Sera.settleRoutedLeg()` sequentially; each entry enters and exits transient locks cleanly.

## 7. SOR Intermediate Settlement & Surplus Handling
`SeraSOR` executes intermediate route legs using transient in-memory balances rather than immediate Vault deposits. This keeps routing gas-efficient, but it also means downstream legs consume statically signed amounts.

### Vault Pull Optimization (First Legs)
For legs where the taker's input is pulled from vault (`takerVaultPull > 0`), settlement computes `transientPhysical = effectiveMatchAmount0 - takerVaultPull` before the vault withdrawal. If `neededFromTaker > transientPhysical`, only the deficit is withdrawn from the vault. If the transient physical tokens alone exceed the cost, the surplus is returned to the taker's vault via `safeTransfer` + `creditLedger`. The taker's spread share remains in vault implicitly.

### Sentinel Surplus Safety Net (Intermediate Legs)
For sentinel legs (`takerVaultPull == 0`), the input tokens are already physically in `Sera.sol` from the previous leg. Any non-zero surplus (`transientPhysical - neededFromTaker`) is returned to the taker's vault via `safeTransfer` + `creditLedger`. In production, the executor calibrates `matchAmount1` values to produce zero intermediate spread, so this safety net block is typically dead code.

### Transient Balance Enforcement
If an intermediate leg produces more output than later signed legs are configured to consume, any leftover transient balance remaining at route end triggers a `TransientBalanceNotZero` revert, ensuring strict conservation of funds across the entire route.

Important distinction:
- final-leg positive slippage still follows the configured `SlippageShare` split and reaches the taker recipient or Vault balance normally
- intermediate surplus is either zero (executor-calibrated) or returned to taker vault (safety net)

### Intent Hardening: Signed Recipient & Deposit Amount
The SOR intent (`INTENT_TYPEHASH`) cryptographically commits to two critical fields:
1. **`recipient`** — The address where the taker's output is delivered. Every terminal leg in the route must have its `order0.recipient` match the signed `intent.recipient`. This prevents an executor from redirecting output to an arbitrary address (output hijacking).
2. **`initialDepositAmount`** — The exact amount to pull from the taker's wallet. The contract verifies `matches[0].order0.initialDepositAmount == intent.initialDepositAmount` and uses this as the wallet pull amount. A value of `0` means vault-only settlement. This prevents an executor from pulling more tokens from the taker's wallet than authorized.

Both fields are bundled into the `IntentParams` struct (see `SeraLib.sol`) and passed as a single calldata parameter to `executeIntent`, reducing stack depth and improving readability.

## 8. Vault `creditLedger` Caller Invariant
`Vault.creditLedger()` no longer checks physical token surplus on-chain before crediting balances. Instead, it relies on a strict caller invariant:

> the caller must transfer the exact token amount into the Vault before calling `creditLedger()` in the same transaction

This is the pattern used by `Sera` during normal settlement and treasury sweeps. Removing the old balance-delta check eliminates a TOCTOU-style dependency on shared physical balances and makes the Vault safer if multiple contracts ever hold `TRADER_ROLE` in the future.

`creditLedger()` also enforces `user != address(0)` as a sanity guard to ensure no vault balance can ever be credited to the zero address, preventing irrecoverable ledger entries.

## 9. EIP-712 Canonical Array Encoding in `executeInstantWithdrawDualSig`
The `WithdrawIntent` struct contains an `address[]` tokens field. Per the EIP-712 specification, each `address` element in an array must be encoded as a 32-byte left-zero-padded word before hashing. Using `abi.encodePacked(address[])` would pack each address into 20 bytes, producing a hash incompatible with standard wallets (MetaMask, Rabby) and SDKs (ethers.js, viem).

The implementation uses a private `_hashAddressArray()` helper that casts each address to `bytes32` before concatenating and hashing, ensuring full EIP-712 compliance and interoperability with all standard signing tools.

This is safe under the intended architecture because:
- `creditLedger()` is restricted to `TRADER_ROLE`
- trusted trader contracts already follow the push-then-credit flow
- violating the invariant would create insolvency, so any future `TRADER_ROLE` integration must preserve it exactly
