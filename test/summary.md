# SOR Test Suite — Detailed Audit Summary

**321 tests** across 25 test suites (counted as `function test*` + `function invariant_*` declarations across `test/*.t.sol`), including fuzz, invariant, EIP-1271, and EIP-7702 suites. This document expands the SOR-focused audit suites in detail, records the re-audit additions, and uses the test files as the source of truth.

## Glossary

| Term | Meaning |
|------|---------|
| **Sentinel** | `matchAmount0 = type(uint256).max` — dynamically resolves to the Sera contract's physical token balance (transient from previous leg) |
| **Shares** | Positive slippage distribution: `setSlippageShares(maker, taker, protocol, total)` in BPS |
| **Hold leg** | Intermediate leg with `recipient = address(sera)` — output stays in Sera for consumption by next leg |
| **Leaf leg** | Final leg with `recipient = taker` — output delivered to taker's wallet |
| **Spread** | Difference between what taker pays and what maker expects. `spread0 = matchAmount0 - executionValue1`, `spread1 = matchAmount1 - executionValue0` |
| **executionValue0** | `Ceil(matchAmount0 × taker.toAmount / taker.fromAmount)` — what taker receives at their price curve |
| **executionValue1** | `Ceil(matchAmount1 × maker.toAmount / maker.fromAmount)` — what maker expects to receive |
| **makerBonus0** | `floor(spread0 × makerShare / total)` — returned to taker's vault as rebate |
| **Dust** | Any ERC-20 balance remaining in the `Sera` contract after settlement; should always be 0 |

---

## Table of Contents

1. [Core Sentinel & Routing](#1-core-sentinel--routing-serasor_nonrigidtsol--19-tests)
2. [Security & Attack Vectors](#2-security--attack-vectors-serasor_attackvectortsol--14-tests)
3. [Extreme Spread, Fees & Dust](#3-extreme-spread-fees--dust-serasor_extremetsol--14-tests)
4. [Edge Cases & Emergency Controls](#4-edge-cases--emergency-controls-serasor_edgecasetsol--13-tests)
5. [Precision & Arithmetic](#5-precision--arithmetic-serasor_precisiontsol--4-tests)
6. [Fuzz Tests](#6-fuzz-tests-serasor_advancedfuzztsol--15-tests)
7. [Low-Level Route Settlement](#7-low-level-route-settlement-seraroutetsol--19-tests)
8. [Extreme Topologies](#8-extreme-topologies-serasor_topologytsol--15-tests)
9. [Settlement Optimization](#9-settlement-optimization-serasor_settlementtsol--14-tests)
10. [Settlement Stress](#10-settlement-stress-serasor_settlementstresststsol--13-tests)
11. [Output Hijacking Fix](#11-output-hijacking-fix-serasor_attackerstealtsol--2-tests)
12. [Deep Audit PoCs](#12-deep-audit-pocs-serasor_deepaudittsol--14-tests)
13. [Coverage Gaps](#13-coverage-gaps-serasor_coveragegapstsol--6-tests)
14. [BPS Precision](#14-bps-precision-serabps_precisiontsol--15-tests)
15. [Smart-Contract Wallet Signers (EIP-1271)](#15-smart-contract-wallet-signers-seraeip1271tsol--8-tests)
16. [EIP-7702 Delegated EOAs](#16-eip-7702-delegated-eoas-sera7702tsol--9-tests)
17. [Vault Solvency Invariant](#17-vault-solvency-vault-solvency-invariant-serainvariant034tsol--3-tests)

---

## Re-audit Additions

The suite was already strong on routing math, zero-dust invariants, replay protection, and topology stress. Recent additions:

| Suite | Test | Why added | What it proves |
|------|------|-----------|----------------|
| `SeraSOR_AttackerSteal.t.sol` | `test_ExecutorCannotRedirectTerminalRecipient_RevertsInvalidRoute` | The file had a placeholder comment but no direct terminal-recipient redirection test. | Executor cannot swap a signed terminal recipient for an attacker-controlled address. |
| `SeraInvariant034.t.sol` | `invariant_solvency_closedUserSet`, `invariant_auxContractsHaveZeroLedger`, `test_spreadPathFires` | E2E issue 034 (vault insolvency) requested an explicit closed-user-set invariant fuzzer. | `IERC20.balanceOf(vault) >= Σ vault.balanceOf(token, user)` over `{actors, treasury}` for every external entry on Vault + Sera + SOR + Batcher with non-zero fees and SOR routing enabled. |
| `Sera7702.t.sol` | 9 tests covering self-delegate + session-key paths for makers, SOR takers, and instant-withdraw flows. | EIP-7702 delegated EOAs need to sign through `SignatureChecker.isValidSignatureNowCalldata()` (which falls through to ERC-1271 on the delegated code). | 7702 EOAs sign as themselves (self-delegate) or via session keys backed by the delegate; rejecting delegates or wrong signers reverts cleanly. |

---

## Additional Passing Suites

The full 321-test count also includes passing suites that are not expanded section-by-section below:

| Suite | Tests |
|------|-------|
| `Sera_FullCoverage.t.sol` | 51 |
| `Sera.t.sol` | 21 |
| `SeraBatcher.t.sol` | 19 |
| `SeraSOR_Permit.t.sol` | 13 |
| `SeraCoverageExtras.t.sol` | 6 |
| `SeraFuzz.t.sol` | 5 |
| `SeraInvariant.t.sol` | 5 |
| `SeraAuditCoverage.t.sol` | 4 |
| `SeraSOR_Positive_Slippage.t.sol` | 0 (stub — setUp only, no test functions) |

---

## 1. Core Sentinel & Routing (`SeraSOR_NonRigid.t.sol` — 19 tests)

| # | Test | Setup | Route Structure | Assertions |
|---|------|-------|-----------------|------------|
| 1 | `test_DynamicFill_TwoLegHop` | Taker: 1000 USDC in vault. M1: 10 ETH. M2: 1 BTC. | Leg 1: 1000 USDC→10 ETH (hold). Leg 2: sentinel ETH→1 BTC (deliver). | `btc.bal(taker) = 1e18`. `usdc.bal(m1) = 1000e18`. `eth.bal(m2) = 10e18`. `eth.bal(sera) = 0`. |
| 2 | `test_DynamicFill_SentinelOnFirstLeg_NoTransient_Reverts` | M1: 10 ETH. Taker has 0 USDC. | Sentinel on leg 1 with no vault deposit. | Reverts `InvalidRoute`. |
| 3 | `test_DynamicFill_SentinelWithZeroTransient_Reverts` | Taker: 1000 USDC. M1: 10 ETH. M2: 1 BTC. | Leg 1: USDC→ETH (deliver to taker, not held). Leg 2: sentinel on BTC (never in transient). | Reverts `InvalidRoute`. |
| 4 | `test_MinOutputGuard_Reverts` | Taker: 1000 USDC. M1: 10 ETH. | 1-leg 1000 USDC→10 ETH. Signed `minOutput = 11e18`. | Reverts `InsufficientOutput`. |
| 5 | `test_MinOutputGuard_Passes` | Same as #4. | Signed `minOutput = 10e18` (exact). | `eth.bal(taker) = 10e18`. `usdc.bal(m1) = 1000e18`. |
| 6 | `test_MaxInputGuard_Reverts` | Taker: 1000 USDC. M1: 10 ETH. | 1-leg. Signed `maxInput = 999e18` (below actual 1000). | Reverts `ExcessiveInput`. |
| 7 | `test_MaxInputGuard_Passes` | Same as #6. | Signed `maxInput = 1000e18` (exact). | `eth.bal(taker) = 10e18`. `usdc.bal(m1) = 1000e18`. |
| 8 | `test_MaxInputGuard_IncludesInitialDeposit` | Taker: 400 vault + 600 wallet. `initialDeposit = 600`. M1: 10 ETH. | Total input = 1000. Signed `maxInput = 999`. | Reverts `ExcessiveInput`. |
| 9 | `test_BuiltInPositiveSlippage_ReducedInput` | Taker: 1000 USDC. M1: 10 ETH. Maker wants 900 USDC (not 1000). | `matchAmount0 = 900` (executor fills less). eV0 = Ceil(900×10/1000) = 9 ETH. | `eth.bal(taker) = 9e18`. `vault.usdc(taker) = 100e18` (kept 100). `usdc.bal(m1) = 900e18`. |
| 10 | `test_DynamicFill_WithMinOutputGuard` | Taker: 1000 USDC. M1: 10 ETH. M2: 1 BTC. | 2-leg sentinel + guards. `maxInput = 1000`, `minOutput = 1 BTC`. | `btc.bal(taker) = 1e18`. `usdc.bal(m1) = 1000e18`. `eth.bal(m2) = 10e18`. |
| 11 | `test_BothGuards_Pass` | Taker: 1000 USDC. M1: 10 ETH. | 1-leg. `maxInput = 1000`, `minOutput = 10`. | `eth.bal(taker) = 10e18`. `usdc.bal(m1) = 1000e18`. |
| 12 | `test_DynamicFill_WithBuiltInPositiveSlippage` | Taker: 1000 USDC. M1: 10 ETH (wants 900 USDC). M2: 1 BTC (wants 9 ETH). | Leg 1 fills 900 (positive slippage). Sentinel Leg 2 resolves to 9 ETH → 0.9 BTC. | `btc.bal(taker) = 0.9e18`. `vault.usdc(taker) = 100e18`. `eth.bal(m2) = 9e18`. |
| 13 | `test_GuardParams_BoundToSignature` | Taker: 1000 USDC. M1: 10 ETH. | Signed with `maxInput=1000, minOutput=10`. Executor executes with `maxInput=0, minOutput=0`. | Reverts `InvalidSignature`. |
| 14 | `test_Executor_CannotLowerGuard` | Same as #13. | Signed `minOutput=10`. Executor passes `minOutput=5`. | Reverts `InvalidSignature`. |
| 15 | `test_FilledAmount_TracksDynamic` | Taker: 1000 USDC. M1: 10 ETH. M2: 1 BTC. | 2-leg sentinel. Sentinel resolves to 10 ETH. | `filledAmount(leg2Hash) = 10e18` (not `type(uint256).max`). |
| 16 | `test_OrderMatchedEvent_EmitsEffectiveAmount` | Same as #15. | 2-leg sentinel. | Event's `matchAmt0` field = `10e18` (not sentinel). |
| 17 | `test_WalletFunded_DynamicFill` | Taker: 1000 USDC in **wallet** (not vault). `initialDeposit = 1000`. M1: 10 ETH. M2: 1 BTC. | 2-leg sentinel, wallet-funded. | `btc.bal(taker) = 1e18`. `usdc.bal(taker) = 0`. `usdc.bal(m1) = 1000e18`. `eth.bal(m2) = 10e18`. |
| 18 | `test_PartialTransientConsumption_Reverts` | Taker: 1000 USDC + 5 ETH in vault. M1: 10 ETH. M2: 2 BTC. | Leg 1: 1000 USDC→10 ETH (hold). Leg 2: **fixed** 15 ETH→2 BTC (10 transient + 5 vault). | Reverts `InvalidRoute` (Vault mixing blocked). |
| 19 | `test_DynamicFill_FeesCalculatedOnEffectiveAmount` | Taker: 1000 USDC. M1: 10 ETH. M2: 1 BTC. Both orders `feeBps = 1000` (10%). | Leg 1 hold → eV0=10 ETH, fee=1 ETH → transient=9 ETH. Sentinel Leg 2: 9 ETH→0.9 BTC. | `btc.bal(taker) = 0.9e18`. `usdc.bal(m1) = 900e18`. `eth.bal(m2) = 9e18`. Treasury = 1 ETH + 100 USDC. |

---

## 2. Security & Attack Vectors (`SeraSOR_AttackVector.t.sol` — 14 tests)

| # | Test | Attack | Setup | Expected |
|---|------|--------|-------|----------|
| 1 | `test_Replay_FullyFilledTakerOrder_Reverts` | Replay fully-filled route | Execute once (1000 USDC→10 ETH). Re-deposit 1000 USDC, replay same sig. | Second execution reverts `OrderFilledAmountExceeded`. |
| 2 | `test_NonExecutor_Reverts` | Unauthorized caller | Attacker (no role) calls `executeIntent` (SOR entry point). | Reverts (Unauthorized). |
| 3 | `test_DirectSettleRoutedLeg_Reverts` | Bypass SOR | Attacker calls `sera.settleRoutedLeg` directly. | Reverts `RouterNotTrusted`. |
| 4 | `test_TakerImpersonation_MixedUsers_Reverts` | Different user in leg 2 | Leg 1: real taker. Leg 2: attacker as taker. | Reverts `InvalidRoute`. |
| 5 | `test_PausedContract_Reverts` | Execution while paused | `sera.pause()` then execute route. | Reverts `SeraPaused`. |
| 6 | `test_ExpiredDeadline_Reverts` | Expired deadline | Warp past timestamp, pass `deadline = timestamp - 1`. | Reverts `MatchExpired`. |
| 7 | `test_SpreadDistribution_AllToProtocol` | Shares `0/0/10000` | Taker: 1000→8 ETH. Maker: 10→800 USDC. Spread: 200 USDC, 2 ETH. | `vault.usdc(owner) = 200e18`. `vault.eth(owner) = 2e18`. `eth.bal(taker) = 8e18`. `usdc.bal(m1) = 800e18`. |
| 8 | `test_SpreadDistribution_AllToTaker` | Shares `0/10000/0` | Same spread as #7. | `usdc.bal(m1) = 1000e18`. `eth.bal(taker) = 8e18`. `vault.eth(m1) = 2e18`. Protocol gets 0. |
| 9 | `test_EmptyRoute_Reverts` | Empty array | 0 matches. | Reverts `EmptyRoute`. |
| 10 | `test_TooManyLegs_Reverts` | Exceeds max | 21 matches (MAX=20). | Reverts `TooManyLegs`. |
| 11 | `test_BlacklistedMaker_Reverts` | Blacklisted maker | `vault.setBlacklisted(maker1, true)`. | Reverts `BlacklistedUser(maker1)`. |
| 12 | `test_ExpiredMakerOrder_Reverts` | Expired maker | `maker.expiration = block.timestamp` (≤ current). | Reverts `OrderExpired`. |
| 13 | `test_InsufficientMakerBalance_Reverts` | Underfunded maker | Maker has 5 ETH, order requires 10. | Reverts `InsufficientVaultBalance`. |
| 14 | `test_VaultSolvency_ComplexRoute` | Solvency proof | 2-leg: 1000 USDC→10 ETH→1 BTC. Initial vault: 5000 USDC, 20 ETH, 5 BTC. | `vault.actual ≥ vault.ledger` for all 3 tokens. `sera.bal = 0` for all 3. |

---

## 3. Extreme Spread, Fees & Dust (`SeraSOR_Extreme.t.sol` — 14 tests)

| # | Test | Shares | Setup | Key Assertions |
|---|------|--------|-------|----------------|
| 1 | `test_NoDust_SingleLeg_MixedShares` | `2500/2500/5000` | Taker 1000→8 ETH, Maker 10→800. Spread: 200 USDC, 2 ETH. | `sera.bal = 0`. **Exact spreads**: Taker gets 50, Maker gets 50, Treasury gets 100. |
| 2 | `test_NoDust_SingleLeg_AllMakerShare` | `10000/0/0` | Same spread. | `sera.bal = 0`. **Exact spreads**: Taker gets full 200 rebate, Treasury 0, Maker 0. |
| 3 | `test_NoDust_ZeroSpread` | `2500/2500/5000` | Taker 1000→10, Maker 10→1000 (exact match). | `sera.bal = 0`. **Exact spreads**: Taker 0, Maker exact, Treasury 0. |
| 4 | `test_NoDust_ThreeLegRoute_SpreadEveryLeg` | `3000/3000/4000` | 3-leg USDC→ETH→BTC→DAI. Spread on all legs. Sentinel legs 2-3. | `sera.bal = 0`. Vault solvent. **Treasury mathematically > 0** on all legs. |
| 5 | `test_NoDust_FeesAndSpreadWithSentinel` | `2500/2500/5000` | 2-leg sentinel. Taker 3% fee, Maker 1%/0.5% fee per leg. | `sera.bal = 0` for USDC/ETH/BTC. **Treasury exact fees** actively extracted. |
| 6 | `test_NoDust_WeiLevelRounding_TwoLeg` | `3333/3333/3334` | 2-leg at **wei level**: 7 USDC→7 ETH (leg 1), sentinel ETH→1 BTC. | `sera.bal = 0`. Vault solvent at wei. |
| 7 | `test_NoDust_WalletFunded_WithSpread` | `2000/3000/5000` | Wallet-funded 1000 USDC. Spread: 200 USDC. | `sera.bal = 0`. **Exact spreads**: Taker 40, Maker 60, Treasury 100. |
| 8 | `test_NoDust_MaximumSpread` | `5000/5000/0` | Taker 1000→1, Maker 100→500. Spread: 950 USDC. | `sera.bal = 0`. **Exact spreads**: Taker 475, Maker 475, Treasury 0. |
| 9 | `test_NoDust_OneSidedSpread` | `2500/2500/5000` | Token 0 spread 500 USDC. Token 1 spread 0 ETH. | `sera.bal = 0`. **Exact spreads**: Taker 125, Maker 125, Treasury 250. |
| 10 | `test_TokenConservation_FullRoute` | `2000/3000/5000` | 2-leg+fees (2%/1%/1.5%/0.5%). 2000 USDC→20 ETH→3 BTC. | `totalSupply before == after` for all tokens. `sera.bal = 0`. Vault solvent. |
| 11 | `test_PartialFill_TwoRoutes` | `3000/3000/4000` | Two routes filling 1000 each of 2000-total taker order (same maker). | `sera.bal = 0` after each. `vault.usdc(taker) = 120e18` (60×2 cumulative rebate). |
| 12 | `test_NoDust_MaxFeesWithSpread` | `0/0/10000` | 100% fee on both sides + spread. | `sera.bal = 0`. Vault solvent. **Treasury exacts 100% of spread/fees**. |
| 13 | `test_NoDust_SharedMaker_TwoLegs` | `2500/2500/5000` | Same maker in both legs of a 2-leg route. | `sera.bal = 0` for 3 tokens. |
| 14 | `test_NoDust_Standalone_Baseline` | `5000/0/5000` | Standalone (non-SOR) match with spread. | `sera.bal = 0`. |

---

## 4. Edge Cases & Emergency Controls (`SeraSOR_EdgeCase.t.sol` — 13 tests)

| # | Test | Setup | Action | Expected |
|---|------|-------|--------|----------|
| 1 | `test_EmergencyWithdraw_FullFlow` | Taker: 1000 USDC. | Request → wait 7199 blocks (reverts) → wait 1 more → execute. | `usdc.bal(taker) = 1000e18` after 7200 blocks. |
| 2 | `test_EmergencyWithdraw_PartialAmount` | Taker: 1000 USDC. | Request 1000, wait 7200, withdraw 500. | `usdc.bal(taker) = 500e18`. |
| 3 | `test_EmergencyWithdraw_ExceedsRequest_Reverts` | Taker: 2000 USDC. | Request 1000, wait 7200, try withdraw 1001. | Reverts `AmountMismatch`. |
| 4 | `test_EmergencyWithdraw_ExpiredReRequest` | Taker: 1000 USDC. | Request 500 → wait 14401 blocks (expired) → re-request 1000 → wait 7200 → withdraw 1000. | `usdc.bal(taker) = 1000e18`. |
| 5 | `test_CrossPath_RouteToStandalone` | Shares `0/0/10000`. Taker: 2000 USDC. M1: 20 ETH (order: 20→2000). | Route fills 10 ETH. Then standalone fills remaining 10 ETH (different taker, same maker). | `filledAmount(makerHash) = 20e18` (100% filled). |
| 6 | `test_CrossRoute_SameMakerTwoRoutes` | Same config. | Route A fills 5 ETH. Route B fills 5 ETH. Same maker. | `filledAmount(makerHash) = 10e18` (50% filled). |
| 7 | `test_ExactRebate_MixedConfig` | Shares `3000/2000/5000`. Taker 1000→8, Maker 10→800. Spread: 200 USDC. | Execute route. | `vault.usdc(taker) = 60e18` (makerBonus0). `vault.usdc(owner) = 100e18` (protocol). `usdc.bal(m1) = 840e18`. Sum = 1000. |
| 8 | `test_ExactRebate_Token1Side` | Same shares. Same orders. | Check ETH-side distribution. | `eth.bal(taker) = 8.6e18`. `vault.eth(m1) = 0.4e18`. `vault.eth(owner) = 1e18`. |
| 9 | `test_DualSig_UuidReplay_Reverts` | Taker: 1000 USDC. | Dual-sig instant withdraw 500 USDC (uuid=42). Replay same uuid. | First succeeds. Second reverts `UuidAlreadyUsed`. |
| 10 | `test_VaultSolvency_SequentialRoutes` | Shares `2500/2500/5000`. Taker: 2000 USDC. M1: 20 ETH. | Two sequential routes, 1000 USDC each. | `vault.actual ≥ vault.ledger` for USDC/ETH after each. `sera.bal = 0`. |
| 11 | `test_OverfillViaRoute_Reverts` | Taker: order `fromAmount = 1000`. | `matchAmount0 = 1001` (exceeds fromAmount). | Reverts `OrderFilledAmountExceeded`. |
| 12 | `test_EmergencyWithdraw_NotBlockedByPause` | Taker: 1000 USDC. | Request, wait 7200 blocks, withdraw (no `whenNotPaused` modifier). | `usdc.bal(taker) = 1000e18`. |
| 13 | `test_MultiLeg_TakerRebate_Accumulates` | Shares `5000/0/5000`. Taker: 1000 USDC. M1: 10 ETH (→800). M2: 1 BTC (→5 ETH). | 2-leg sentinel. Leg 1 rebate: 100 USDC. Leg 2 rebate: 2 ETH. | `vault.usdc(taker) = 100e18`. `vault.eth(taker) = 2e18`. `sera.bal = 0` for all 3. |

---

## 5. Precision & Arithmetic (`SeraSOR_Precision.t.sol` — 4 tests)

| # | Test | Setup | Assertions |
|---|------|-------|------------|
| 1 | `test_CombinedFeesAndSpread` | Shares `2500/2500/5000`. Taker 1000→8 ETH (1% fee). Maker 10→800 (0.5% fee). Spread: 200 USDC, 2 ETH. | `vault.actual ≥ vault.ledger` for USDC/ETH. `vault.usdc(owner) > 0`. `vault.eth(owner) > 0`. |
| 2 | `test_PartialFillThenRoute` | Taker: 1000 USDC (1000→10 ETH order). | Standalone fill 500 → `filledAmount = 500`. Another standalone fill 500 → `filledAmount = 1000`. | `filledAmount = 1000e18`. |
| 3 | `test_VaultSolvency_MaxFees` | `feeBps = 1e14` (100%) on both sides. | `vault.actual ≥ vault.ledger` for both tokens. |
| 4 | `test_SmallAmountPrecision` | 100 wei USDC, 10 wei ETH (tiny amounts). | `vault.actual ≥ vault.ledger` at wei level. |

---

## 6. Fuzz Tests (`SeraSOR_AdvancedFuzz.t.sol` — 15 tests)

| # | Test | Fuzzed Params | Constraints | Invariants |
|---|------|---------------|-------------|------------|
| 1 | `testFuzz_RandomSlippageShares` | `makerShare`, `takerShare`, `protocolShare`, `feeBpsTaker`, `feeBpsMaker`. | `totalShare > 0`. Fixed token amounts. | Solvency verified. Zero Dust. |
| 2 | `testFuzz_ExtremeAmounts` | `tFromAmount`, `tToAmount`, `mFromAmount`, `mToAmount` (< uint64 max). | Prices overlap without overflow. | Same solvency + dust invariants. |
| 3 | `testFuzz_StrictSpreadRebateMath` | `mShare`, `tShare`, `pShare`, `tAmount`, `m1Amount`. | Random valid prices. | **Exact `assertEq`**: Treasury vault balance == `spread × pShare / total`. |
| 4 | `testFuzz_WalletFunded_ERC20Boundaries` | `initDeposit` (100 -> uint128.max). | Sourced from strict ERC20 allowance. | No stranded dust in Sera after wallet injection. |
| 5 | `testFuzz_MultipleMatchingMakers` | `f1`, `f2`, `f3`. | 3 different makers @ random depths. | Vault captures fractions across multi-fills without dropping wei. |
| 6 | `testFuzz_FeesAndSlippageIntersection` | `tFee`, `mFee` (up to 100%). | 100% protocol spread. | No underflow or `InsufficientBalance` reverts. Zero dust. |
| 7 | `testFuzz_MaxIntegerMathBounds` | `x` (uint112.max → uint128.max). | Stresses `mulDiv` ceiling. | Settlement resolves cleanly at extreme values. |
| 8 | `testFuzz_TrueThreeLegRoute` | `takerAmount`, `feeTaker`, `feeM1`, `feeM2`, `feeM3`. | 3 full sentinel legs. | Zero dust across 4 tokens (A/B/C/D). |
| 9 | `testFuzz_PartialFillAccumulation` | `totalAmount`, `firstFill`. | Two sequential partial fills of same order. | `filledAmount` accumulates correctly. Solvency. Zero dust. |
| 10 | `testFuzz_SpreadConservation` | `mShare`, `tShare`, `pShare`, `takerAmount`. | Random shares + large spread. | Vault solvent (`ledger ≤ physical`). `totalSupply` unchanged. No dust. |
| 11 | `testFuzz_EnvelopeGuards_Boundaries` | `takerAmount`, `maxInput`, `minOutput`. | Random guard values. | Correctly reverts when violated, passes when satisfied. |
| 12 | `testFuzz_TokenConservation` | `takerAmount`, `fee`. | Random amounts + fees. | `totalSupply` unchanged for both tokens after settlement. |
| 13 | `testFuzz_TwoLegSentinel_RandomPricing` | `takerAmount`, `makerRate` (0.1x–5x). | 2-leg sentinel, randomized L2 pricing. | Transient balance fully consumed. Zero dust. Vault solvent. |
| 14 | `testFuzz_AsymmetricPricingRatios` | `fromVal`, `toVal`. | Extreme price ratios (up to 10M:100). | `mulDiv` handles extreme ratios without overflow. Solvency. |
| 15 | `testFuzz_FullDistributionInvariant` | `mShare`, `tShare`, `pShare`, `tFee`, `mFee`. | All share/fee combos. | Vault solvent. Supply conserved. Zero dust. |

---

## 7. Low-Level Route Settlement (`SeraRoute.t.sol` — 19 tests)

| # | Test | Description |
|---|------|-------------|
| 1 | `test_matchOrdersRouted_SingleLeg` | Single routed leg, basic settlement. |
| 2 | `test_matchOrdersRouted_TwoLegHop` | 2-leg A→B→C hop with hold intermediate. |
| 3 | `test_matchOrdersRouted_SplitAndMultileg` | 3-leg route with split topology. |
| 4 | `test_matchOrdersRouted_WithFees` | Routed legs with fees. |
| 5 | `test_matchOrdersRouted_InvalidSignature` | Invalid taker signature → revert. |
| 6 | `test_matchOrdersRouted_RejectsDifferentTakers` | Mixed takers in legs → revert. |
| 7 | `test_matchOrdersRouted_RevertsWithoutTrustedRouter` | Non-trusted router → revert. |
| 8 | `test_matchOrdersRouted_SplitMultileg_MakerExpiredReverts` | Expired maker mid-route → revert. |
| 9 | `test_matchOrdersRouted_ComplexMultilegWithFees` | 3-leg with fees on all legs. |
| 10 | `test_swapRouted_SingleLeg` | Swap variant of routed settlement. |
| 11 | `test_executeIntent_RejectsReplay` | Same signed SOR order cannot be executed twice, even if the executor swaps in a new maker leg on replay. |
| 12 | `test_executeRoute_VaultPull_VaultReturn` | Fund source: vault → vault. |
| 13 | `test_executeRoute_VaultPull_WalletReturn` | Fund source: vault → wallet. |
| 14 | `test_executeRoute_WalletPull_VaultReturn` | Fund source: wallet → vault. |
| 15 | `test_executeRoute_WalletPull_WalletReturn` | Fund source: wallet → wallet. |
| 16 | `test_executeRoute_WalletPull_ThirdPartyReturn` | Fund source: wallet → third-party address. |
| 17 | `test_executeRoute_MixedFunds` | Mixed vault + wallet combined inputs. |
| 18 | `test_settleRoutedLeg_SameTokenMatch_Reverts` | Same-token match via routed leg → revert. |
| 19 | `test_settleRoutedLeg_SelfMatch_Reverts` | Self-match via routed leg → revert. |

---

## 8. Extreme Topologies (`SeraSOR_Topology.t.sol` — 15 tests)

| # | Test | Topology | Deposits | Fees | Assertions |
|---|------|----------|----------|------|------------|
| 1 | `test_FiveLegLinearChain_WithFees` | 5-leg A→B→C→D→E→F, all sentinel after leg 1 | Taker: 10000 A. 5 makers: 10000 each of B–F. | 5%/3%, 5%/2%, 5%/1%, 5%/4%, 5%/2% per leg | Taker received F. Vault solvent for 6 tokens. No dust for 6 tokens. |
| 2 | `test_DiamondWithFees_AllLegs` | 4-leg diamond: A→B (fixed), A→C (sentinel), B→D (sentinel), C→D (sentinel) | Taker: 2000 A. Makers provide B, C, D. | 3%, 2%, 4%, 5% per leg | Taker received D. Solvent. No dust. |
| 3 | `test_TreeFanOut_ThreeBranches_Reverts` | 4-leg tree: A→B→C (fixed), B→D (sentinel), B→E (sentinel) | Taker: 5000 A. Makers provide B, C, D, E. | 3%, 5%, 4%, 2% per leg | Reverts `InvalidRoute` (multi-out blocked). |
| 4 | `test_SameToken_Recirculation_A_B_A_C` | 3-leg A→B→A→C (token A recirculates) | Taker: 1000 A. Makers provide B, A, C. | 0% | Taker received C. No dust A, B, C. |
| 5 | `test_WalletFunded_ThreeLeg_WithFees` | 2-leg wallet-funded A→B→C | Taker: 2000 A in **wallet**. `initialDeposit=2000`. | 3%, 2% | Taker received C. `A.bal(taker) = 0`. Solvent. |
| 6 | `test_MaxFees_TwoLeg_Sentinel` | 2-leg A→B→C. `feeBps=5000` (50%). Shares `0/0/10000`. | Taker: 10000 A. M1: 5000 B. M2: 2000 C. | 50% both legs | Taker received C. Treasury has fees. No dust. |
| 7 | `test_WeiLevel_ThreeHop_Sentinel` | 3-leg (1001 wei → 11 wei → 7 wei → 3 wei) | Taker: 1001 wei A. Makers: tiny amounts. | 0% | Taker received ≥1 wei D. No dust. Solvent at wei. |
| 8 | `test_TenLegRoute_Solvency` | 10-leg A↔B zigzag (A→B→A→B→... for 10 legs) | Taker: 10000 A. 10 makers with B/A alternating. | 0%–8% varied | Taker received final token. Solvent. No dust. |
| 9 | `test_PartialFillMaker_ThenRouteConsumesRemainder` | Standalone fills maker 300/1000. Then SOR route fills remaining 700. | Taker: 2000 A. Maker: 1000 B (order: 1000→500). | 0% | `filledAmount(maker) = 1000e18` (100%). No dust. |
| 10 | `test_DiamondAsymmetricFees_ZeroVsMax` | 4-leg diamond. Branch 1: 0% fee. Branch 2: 80% fee. | Taker: 5000 A. Makers provide B, C, D. | 0% vs 80% | Taker received D. No dust. Solvent. |
| 11 | `test_EnvelopeGuards_ThreeLeg_Passes` | 2-leg A→B→C. Signed `maxInput = 2000`, `minOutput = 1`. | Taker: 2000 A. | 0% | Passes. Taker received C. |
| 12 | `test_EnvelopeGuards_ThreeLeg_MinOutputReverts` | Same as #11 but `minOutput = 999999e18` (unreachable). | Same. | 0% | Reverts `InsufficientOutput`. |
| 13 | `test_SameMaker_TwoLegs_DifferentTokenPairs` | 2-leg A→B→C. **Same maker** for both legs. | Taker: 2000 A. Maker1: 2000 B + 2000 C. | 0% | Taker received C. No dust. |
| 14 | `test_AllSharesToMaker_TwoLeg_Sentinel` | 2-leg sentinel. Shares `10000/0/0`. Taker 2000→200 B (generous). | Taker: 2000 A. M1: 500 B. M2: 100 C. | 0% | Taker received C. `vault.usdc(owner) = 0` (zero protocol revenue). No dust. |
| 15 | `test_ChristmasTree_AllSentinel_CircularChain` | **19-leg ALL SENTINEL** linear chain. 10 tokens (T0–T9) with 12 circular reuses. Path: T0→T1→T2→T3→T4→T5→T0(!)→T6→T7→T8→T9→T3(!)→T1(!)→T4(!)→T7(!)→T2(!)→T5(!)→T8(!)→T6(!)→T9(final). | Taker: 10000 T0. 19 makers: 1500–5000 each. `maker.toAmount = 1 ether` (very favorable). | Varied: 0%, 2%, 3%, 5%, 7%, 8% per leg. Shares `2500/2500/5000`. Taker price ratios: 1:2 to 1:10. | `T9.bal(taker) > 0`. `sera.bal = 0` for all 10 tokens. |

---

## 9. Settlement Optimization (`SeraSOR_Settlement.t.sol` — 14 tests)

Tests targeting the vault pull optimization and sentinel surplus safety net introduced in the settlement refactor.

| # | Test | Category | Setup | Key Assertions |
|---|------|----------|-------|----------------|
| 1 | `test_VaultPull_FirstLeg_RetainsSurplus` | Vault Pull | Taker 1000A→8B. Maker 10B→800A. Spread 200. Shares 25/25/50. | `vault.A(taker) = 50` (spread retained). `A.bal(m1) = 850`. `vault.A(treasury) = 100`. No dust. |
| 2 | `test_VaultPull_ZeroSpread_FullDebit` | Vault Pull | 1:1 pricing. 100A→100B. | `vault.A(taker) = 0` (full consumption). `B.bal(taker) = 100`. |
| 3 | `test_VaultPull_FirstLeg_WithFees` | Vault Pull | Taker 3% fee, Maker 1% fee. spread 200. | `protocolFee0 = mulDiv(800, 100, 10000)`. Exact assertions on maker, taker, treasury. |
| 4 | `test_Sentinel_IntermediateSpread_SurplusToVault` | Sentinel | 2-leg. Leg 1 exact, Leg 2 spread 30B. | `vault.B(taker) > 0` (surplus returned). No dust. |
| 5 | `test_Sentinel_MECalibrated_ZeroSurplus` | Sentinel | 2-leg. executor-calibrated: zero spread on both legs. | `vault.B(taker) = 0`. `vault.A(taker) = 0`. Taker received C. |
| 6 | `test_PerLegFees_DifferentFeesPerLeg` | Per-leg Fees | 2-leg. Leg 1: 5% taker. Leg 2: 10% maker. executor-calibrated. | Taker A consumed. Maker1 vault A = 1000. No dust. Solvency. |
| 7 | `test_PerLegFees_EscalatingTakerFees` | Per-leg Fees | 3-leg. Leg 1: 0%. Leg 2: 0%. Leg 3: 5% taker. | `D.bal(taker) = 125e18 - 5%`. Exact fee computed via `mulDiv`. |
| 8 | `test_PerLegFees_HighMakerFee_SecondLeg` | Per-leg Fees | 2-leg. Leg 2: 10% maker fee. | `vault.B(m2) = 45`. `vault.B(treasury) = 5`. |
| 9 | `test_DynamicShares_ChangeBetweenRoutes` | Shares | Route 1: 25/25/50. Route 2: 0/0/100. Same maker pricing. | After R1: 1050A. After R2: 50A (no spread retained). |
| 10 | `test_Shares_AllMaker` | Shares | 100/0/0 shares. Spread 200. | `vault.A(taker) = 200` (maker implicit bonus stays). |
| 11 | `test_Shares_AllTaker` | Shares | 0/100/0 shares. Spread 200. | `vault.A(taker) = 0`. `A.bal(m1) = 1000` (spreadToTaker0 inflates executionValue1). |
| 12 | `test_Combined_VaultPullAndSentinelSurplus` | Combined | 2-leg. Leg 1: vault pull with spread. Leg 2: sentinel with spread. | Taker A retained > 0. Taker B surplus > 0 (safety net). Taker received C. |
| 13 | `test_Combined_ThreeLeg_MECalibrated_PerLegFees` | Combined | 3-leg. 2% taker L1, 0% L2, 5% taker L3. executor-calibrated zero spread. | `D.bal(taker) = 245e18 - 5%` exactly. No B/C surplus. A fully consumed. |
| 14 | `test_Audit_Fixed_MixedSettlementRefundsPhysicalSurplus` | Audit Fix | Mixed transient (40 wallet) + vault (60). Maker needs 80. Spread 20A. Shares 25/25/50. | `vault.A(taker) = 5` (exact taker spread). `A.bal(m1) = 85` (maker + bonus). `vault.A(treasury) = 10`. No dust. Solvent. |

---

## 10. Settlement Stress (`SeraSOR_SettlementStress.t.sol` — 13 tests)

Stress tests for settlement math under extreme conditions.

| # | Test | Category | Key Feature |
|---|------|----------|-------------|
| 1 | `testFuzz_SingleLeg_RandomPricing` | Fuzz | Random pricing with solvency invariant. |
| 2 | `testFuzz_TwoLeg_MECalibrated_PerLegFees` | Fuzz | executor-calibrated 2-leg with random per-leg fees. |
| 3 | `testFuzz_VaultPull_RandomSharesAndFees` | Fuzz | Random slippage shares and fees with vault pull. |
| 4 | `test_AsymmetricPricing_HighRatio` | Deterministic | High price ratio settlement. |
| 5 | `test_AsymmetricPricing_LowRatio` | Deterministic | Low price ratio settlement. |
| 6 | `test_BoundaryShares_ExtremeSkew` | Deterministic | Extreme slippage share skew. |
| 7 | `test_BoundaryShares_Minimum` | Deterministic | Minimum slippage shares. |
| 8 | `test_LargeValue_VaultPull` | Deterministic | Large value vault pull. |
| 9 | `test_LargeValue_WithSpread` | Deterministic | Large value with spread. |
| 10 | `test_MaxFees_TwoLeg_AllParties` | Deterministic | Max fees on 2-leg route. |
| 11 | `test_Sequential_FiveRoutes_CumulativeSpread` | Deterministic | 5 sequential routes with cumulative spread. |
| 12 | `test_WeiLevel_TwoLeg_Sentinel` | Deterministic | Wei-level 2-leg sentinel. |
| 13 | `test_WeiLevel_VaultPull` | Deterministic | Wei-level vault pull. |

---

## 11. Output Hijacking Fix (`SeraSOR_AttackerSteal.t.sol` — 2 tests)

Validates the security patch which binds the recipient address to the terminal route execution.

| # | Test | Description |
|---|------|-------------|
| 1 | `test_ExecutorCannotRedirectTerminalRecipient_RevertsInvalidRoute` | Attempts to overwrite the signed terminal recipient with an attacker-controlled recipient on the only leg. | Reverts `InvalidRoute`. |
| 2 | `test_SingleLeg_HoldOutput_RevertsInvalidRoute` | Attempts to maliciously hold the final leg output in the Sera contract instead of sending to recipient. | Reverts `InvalidRoute`. |

---

## 12. Deep Audit PoCs (`SeraSOR_DeepAudit.t.sol` — 14 tests)

Tests validating all security findings, edge cases, and architectural observations from the comprehensive security audit.

| # | Test | Validates | Description |
|---|------|-----------|-------------|
| 1 | `test_Audit1_PartialFill_SkipsSignature` | M-1 | Executor can partially execute an order multiple times without re-verifying the signature. |
| 2 | `test_Audit2_EmergencyWithdraw_PartialAmountAllowed` | M-3 | Users can emergency withdraw partial amounts iteratively over time without losing the request lock. |
| 3 | `test_Audit3_CreditLedger_NoTransferVerification` | Trust Boundary | Vault ledger crediting deliberately relies on the authorized caller to transfer assets before crediting balances. |
| 4 | `test_Audit5_NoCrossContractReplay` | Domain Separator | Orders are strictly bound to the specific `Sera.sol` instance using EIP-712 domain versioning. |
| 5 | `test_Audit6_FullyFilledOrder_CannotBeRefilled` | Protocol Invariant | Ensures `matchAmount` limits execution and fully-filled orders systematically revert. |
| 6 | `test_Audit7_SORUuid_PerUserIsolation` | Protocol Invariant | Uuid values are correctly scoped per-user. Mapped tracking does not contaminate across makers. |
| 7 | `test_Audit8_MaxInputZero_MeansNoCap` | Envelope Guards | Zero-value envelope guard disables checks, consciously placing risk on the signer for terminal routing bounds. |
| 8 | `test_Audit9_EmergencyWithdraw_ExpiresAfterWindow` | L-3 | Grace period accurately cuts off withdrawals beyond the 7200-block window unless re-requested. |
| 9 | `test_Audit10_RescueToken_CannotStealTracked` | Protocol Invariant | Ensure `rescueToken` explicitly bans retrieving actively whitelisted user liquidity tokens. |
| 10 | `test_Audit11_SlippageShares_MustSumToTotal` | Configuration | Slippage spread distribution securely sums up to exactly the 10000 Bps denominator with no loss. |
| 11 | `test_Audit12_SingleLeg_SkipsTransientCheck` | Universal Invariant | Single-hop routes pass the universal transient zero-balance check (trivially, since no balances accumulate when initialDepositAmount = 0). |
| 12 | `test_Audit13_ZeroSpread_NoUnderflow` | Arithmetic Limits | Explicit limits and bounds mapping on exact `executionValue = matchAmount` pricing, testing 0 margin rounding. |
| 13 | `test_Audit14_GhostLiquidity_Prevention` | Invariant | Vault properly bounds internal storage mapping to token balances preventing unbacked credits. |
| 14 | `test_Audit15_UuidNamespace_NoCrossContamination` | UUID Space | Validation of cross-method collision prevention across `emergencyWithdraw` vs normal SOR routing logic. |

---

## 13. Coverage Gaps (`SeraSOR_CoverageGaps.t.sol` — 6 tests)

Tests specifically written to cover complex missing pathing logic, including wallet funding inside diamonds and terminal output verifications.

| # | Test | Category | Validation |
|---|------|----------|------------|
| 1 | `test_Gap1_Diamond_IntermediatePositiveSlippage` | Diamond | Fully tracks complex positive slippage sharing mechanisms and exact division rounding math on intermediate node branches. |
| 2 | `test_Gap2_Diamond_WalletFunded` | Wallet Diamond | Complex tree branch funding split effectively across wallet limits (`initialDepositAmount`) and `vault` balances concurrently. |
| 3 | `test_Gap3_ConvergentDiamond_BothTerminal` | Terminal Fan-In | Both terminal legs accurately sum output tracking back to a single shared taker destination. |
| 4 | `test_Gap3b_ConvergentDiamond_WithFees_EnvelopeGuard` | Fan-in + Rules | Ensures rigorous bounds mapping is verified across spread sharing, multiple protocol fees, and dynamic pricing outputs. |
| 5 | `test_Gap3c_ConvergentDiamond_MinOutputReverts` | Protection | High slippage or fees pulling output below bounds successfully halts and rolls-back the entire fan-in tree. |
| 6 | `test_Gap5_FeesAndPositiveSlippage_Together` | Combined Overlap | Proves out simultaneous 10% Taker/Maker fees combined perfectly with dynamic 25/25/50 positive slippage distribution math. |

---

## 14. BPS Precision (`SeraBPS_Precision.t.sol` — 15 tests)

Tests specifically validating the expanded `BPS_DENOMINATOR = 1e14` fee precision, overflow safety, and sub-basis-point granularity.

| # | Test | Category | Validation |
|---|------|----------|------------|
| 1 | `test_OneCentFeeOnMillionDollarOrder` | Precision | `feeBps = 1_000_000` on $1M (18-dec) yields ~$0.01 equivalent. |
| 2 | `test_OneCentFeeOnTenMillionUSDCOrder_True6Decimals` | Precision | `feeBps = 1_000` on $10M (true 6-dec USDC) yields exactly $0.01 = 10,000 units. |
| 3 | `test_FeeGranularity` | Precision | Verifies the granularity stepping under `BPS_DENOMINATOR = 1e14`. |
| 4 | `test_OverflowSafety_MaxAmountMaxFee` | Overflow | `mulDiv(type(uint256).max, 1e14, 1e14) == type(uint256).max`. |
| 5 | `test_OverflowSafety_LargeAmountSmallFee` | Overflow | Large amount × small fee returns a clean value without overflow. |
| 6 | `test_OverflowSafety_NearMaxU256` | Overflow | Near-max `uint256` amounts behave correctly under `mulDiv`. |
| 7 | `test_ZeroFee` | Bounds | `mulDiv(amount, 0, 1e14) == 0` — zero fee produces zero. |
| 8 | `test_MinimumNonZeroFee` | Bounds | `mulDiv(1e14, 1, 1e14) == 1` — smallest non-zero fee on smallest qualifying amount. |
| 9 | `test_BelowMinimumFee_RoundsToZero` | Bounds | `feeBps` below the granularity threshold for the given amount rounds to zero. |
| 10 | `test_Settlement_OneCentFee_OnChain` | E2E | Full on-chain settlement with `feeBps` chosen for $0.01 on a $1M trade. Vault solvency + zero dust verified. |
| 11 | `test_Settlement_TenMillionUSDC_OneCentFee_True6Decimals` | E2E | Same E2E flow on a 6-decimal stablecoin path. |
| 12 | `test_MaxFeeBps_IsExactly100Percent` | Bounds | `feeBps = 1e14` represents exactly 100% — `mulDiv` returns the full amount. |
| 13 | `test_FeeBps_JustOverMax_Reverts` | Bounds | `feeBps > 1e14` reverts `InvalidFee` in `_validateOrderCommon`. |
| 14 | `testFuzz_FeeNeverExceedsAmount` | Fuzz | For random `(amount, feeBps)` where `feeBps ≤ 1e14`: `mulDiv(amount, feeBps, 1e14) ≤ amount`. |
| 15 | `testFuzz_FeeMonotonicallyIncreases` | Fuzz | For `fee1 ≤ fee2 ≤ 1e14`: `mulDiv(amount, fee1, 1e14) ≤ mulDiv(amount, fee2, 1e14)`. |

---

## 15. Smart-Contract Wallet Signers (`SeraEIP1271.t.sol` — 8 tests)

Validates that maker, taker, and instant-withdraw signature paths route through OpenZeppelin's `SignatureChecker`, which falls through to ERC-1271 `isValidSignature()` on contract wallets (Safe, Argent, ERC-4337 accounts).

| # | Test | Path | What it proves |
|---|------|------|----------------|
| 1 | `test_matchOrders_SmartWalletMaker` | `Sera.matchOrders` | A contract-wallet maker order signed via ERC-1271 settles cleanly. |
| 2 | `test_matchOrders_SmartWalletBothSides` | `Sera.matchOrders` | Both taker and maker can be smart-wallet signers in the same trade. |
| 3 | `test_matchOrders_RejectsInvalidSmartWalletSig` | `Sera.matchOrders` | A wallet that returns the non-magic value reverts `InvalidSignature`. |
| 4 | `test_SOR_SmartWalletTaker_SingleLeg` | `SeraSOR.executeIntent` | SOR taker signed by an ERC-1271 wallet executes a single-leg route. |
| 5 | `test_SOR_RejectsWrongSmartWalletSig` | `SeraSOR.executeIntent` | SOR rejects a signature produced by a different wallet. |
| 6 | `test_instantWithdraw_SmartWalletUser` | `executeInstantWithdrawDualSig` | User signature can come from a contract wallet. |
| 7 | `test_instantWithdraw_SmartWalletExecutor` | `executeInstantWithdrawDualSig` | Executor signature can come from a contract wallet. |
| 8 | `test_instantWithdraw_SmartWalletExecutor_WrongSigner_Reverts` | `executeInstantWithdrawDualSig` | A contract executor whose `isValidSignature` rejects the digest reverts. |

---

## 16. EIP-7702 Delegated EOAs (`Sera7702.t.sol` — 9 tests)

Validates that EOAs delegated under EIP-7702 — both self-delegated and delegating to a session-key contract — are accepted as signers across maker, SOR taker, and instant-withdraw flows. Behaviour piggybacks on `SignatureChecker`: when an EOA address has code (because of a 7702 delegation), the checker calls into the delegate's `isValidSignature`.

| # | Test | Path | Setup |
|---|------|------|-------|
| 1 | `test_7702_Maker_SelfDelegate_ValidatesEOAKey` | maker | EOA self-delegates; ECDSA signature still validates. |
| 2 | `test_7702_Maker_SessionKey_ValidatesViaDelegate` | maker | Delegate authorises a session key to sign on the EOA's behalf. |
| 3 | `test_7702_Maker_ECDSA_SkippedWhenDelegateRejects` | maker | Delegate that rejects the digest reverts even if raw ECDSA recovers the EOA. |
| 4 | `test_7702_Maker_WrongSigner_Reverts` | maker | A signature by a non-authorised key reverts. |
| 5 | `test_7702_SOR_Taker_SelfDelegate` | SOR | Self-delegated taker signs SOR intents. |
| 6 | `test_7702_SOR_Taker_SessionKey` | SOR | Session-key taker executes a SOR route. |
| 7 | `test_7702_InstantWithdraw_SelfDelegate` | instant withdraw | Self-delegated user signs the withdraw intent. |
| 8 | `test_7702_InstantWithdraw_7702Executor` | instant withdraw | Executor itself is a 7702-delegated EOA. |
| 9 | `test_7702_InstantWithdraw_7702Executor_DelegateRejects_Reverts` | instant withdraw | Executor delegate rejects the digest → revert. |

---

## 17. Vault Solvency Invariant (`SeraInvariant034.t.sol` — 3 tests)

Targeted invariant fuzz of vault solvency (vault insolvency). The handler exercises every external entry point on Vault + Sera + SOR + Batcher with non-zero fees, SOR routing, and emergency / instant withdraws over a closed set of `{actors, treasury}`.

| # | Test | Type | Assertion |
|---|------|------|-----------|
| 1 | `invariant_solvency_closedUserSet` | invariant | `IERC20(token).balanceOf(vault) >= Σ vault.balanceOf(token, user)` over the closed user set. Strict combined form of `assertVaultSolvency` + `assertVaultLedgerConservation`. |
| 2 | `invariant_auxContractsHaveZeroLedger` | invariant | Auxiliary contracts (Sera, SeraSOR, SeraBatcher) never accumulate vault ledger balances. |
| 3 | `test_spreadPathFires` | reachability | Verifies the fuzzer actually exercises the spread / `creditLedger` paths it claims to cover (ghost counters > 0). |
