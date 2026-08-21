// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

/// @notice A runnable, local-only tour of the v2 protocol's user flows.
/// @dev Run against Anvil through script/run-local-experience.sh. The script
/// deploys an isolated stack, performs real broadcasts, and reverts on a bad
/// post-condition, so it is both a demo and a lightweight integration check.
contract ExperienceLocal is Script {
    /// @dev All fixture tokens have 18 decimals, so amounts are expressed in
    /// whole-token units rather than raw ERC-20 decimals throughout this file.
    uint256 private constant UNIT = 1 ether;

    /// @dev Human-readable execution data collected during the walkthrough and
    /// printed together at the end. Values are raw 18-decimal fixture amounts.
    struct ExperienceSummary {
        uint256 initialTakerUsdtInVault;
        uint256 initialMakerUsdcInVault;
        uint256 initialMakerSgdInVault;
        uint256 directUsdtSpent;
        uint256 directUsdcReceivedExternally;
        uint256 batchFailedMask;
        uint256 batchSuccessfulInput;
        uint256 sorWalletFunding;
        uint256 sorIntermediateUsdc;
        uint256 sorSgdCreditedToVault;
        uint256 instantWithdrawal;
        uint256 delayedWithdrawal;
        bool sorUuidConsumed;
        bool pauseBlockedDeposit;
    }

    ExperienceSummary private summary;

    /// @notice Deploy a disposable local stack and run each end-user flow in order.
    /// @dev The shell wrapper completes the final delayed-withdrawal execution:
    /// this script only creates its request, because the delay is block based.
    function run() external {
        // Five roles make the trust boundaries visible: an administrator, a
        // taker, two makers for the two-hop route, and a distinct executor.
        uint256 deployerKey = vm.envUint("DEMO_DEPLOYER_PRIVATE_KEY");
        uint256 takerKey = vm.envUint("DEMO_TAKER_PRIVATE_KEY");
        uint256 makerOneKey = vm.envUint("DEMO_MAKER_ONE_PRIVATE_KEY");
        uint256 makerTwoKey = vm.envUint("DEMO_MAKER_TWO_PRIVATE_KEY");
        uint256 executorKey = vm.envUint("DEMO_EXECUTOR_PRIVATE_KEY");

        address deployer = vm.addr(deployerKey);
        address taker = vm.addr(takerKey);
        address makerOne = vm.addr(makerOneKey);
        address makerTwo = vm.addr(makerTwoKey);
        address executor = vm.addr(executorKey);

        (Sera sera, SeraBatcher batcher, SeraSOR sor, MockStableCoin usdt, MockStableCoin usdc, MockStableCoin sgd) =
            _deploy(deployerKey, deployer, executor);

        // Put each participant's sell-side asset in Vault custody before any
        // signed order is matched. Matching only moves these ledger balances.
        _mintAndDeposit(takerKey, taker, usdt, sera, 2_000 * UNIT);
        _mintAndDeposit(makerOneKey, makerOne, usdc, sera, 4_000 * UNIT);
        _mintAndDeposit(makerTwoKey, makerTwo, sgd, sera, 4_000 * UNIT);
        summary.initialTakerUsdtInVault = sera.vault().balanceOf(address(usdt), taker);
        summary.initialMakerUsdcInVault = sera.vault().balanceOf(address(usdc), makerOne);
        summary.initialMakerSgdInVault = sera.vault().balanceOf(address(sgd), makerTwo);

        uint48 expiry = uint48(block.timestamp + 1 days);
        _directAndPartialMatch(sera, executorKey, takerKey, makerOneKey, taker, makerOne, usdt, usdc, expiry);
        _batchModes(sera, batcher, executorKey, takerKey, makerOneKey, taker, makerOne, usdt, usdc, expiry);
        _sorRoute(sera, sor, executorKey, takerKey, makerOneKey, makerTwoKey, taker, makerOne, makerTwo, usdt, usdc, sgd, expiry);
        _instantAndDelayedWithdraw(sera, executorKey, takerKey, executor, taker, sgd);
        _pauseCheck(sera, deployerKey, taker, usdt);

        _printSummary(sera, batcher, sor, usdt, usdc, sgd, taker, makerOne, makerTwo);
    }

    /// @dev Deploy mock assets and the complete Sera stack, then assign only
    /// the roles required for the local walkthrough.
    /// @param deployerKey Private key that broadcasts contract deployment/configuration.
    /// @param deployer Administrator of Vault and Sera.
    /// @param executor Account authorized to submit matches and SOR routes.
    /// @return sera Core matching engine.
    /// @return batcher Batch execution wrapper.
    /// @return sor Smart Order Router wrapper.
    /// @return usdt Input asset for direct matches and SOR.
    /// @return usdc Intermediate SOR asset.
    /// @return sgd Final SOR output and withdrawal asset.
    function _deploy(uint256 deployerKey, address deployer, address executor)
        private
        returns (Sera sera, SeraBatcher batcher, SeraSOR sor, MockStableCoin usdt, MockStableCoin usdc, MockStableCoin sgd)
    {
        vm.startBroadcast(deployerKey);
        // The route is USDT -> USDC -> SGD. Mock tokens keep this walkthrough
        // deterministic and ensure no public-network asset can be touched.
        usdt = new MockStableCoin("USDT");
        usdc = new MockStableCoin("USDC");
        sgd = new MockStableCoin("SGD");
        Vault vault = new Vault(deployer);
        sera = new Sera(deployer, vault);
        // Vault accepts deposits and withdrawals only from Sera, never directly
        // from a user, so grant the settlement engine its Trader role first.
        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        sor = new SeraSOR(address(sera));
        batcher = new SeraBatcher(address(sera), address(sor));
        // Both wrappers are executor delegates; the human-like executor below
        // is the account that submits the walkthrough's match transactions.
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        // SOR alone may call settleRoutedLeg, which bypasses per-leg taker
        // signatures after it has validated the one signed route envelope.
        sera.setTrustedRouter(address(sor));
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdt); tokens[1] = address(usdc); tokens[2] = address(sgd);
        uint256[] memory minimums = new uint256[](3);
        minimums[0] = 1; minimums[1] = 1; minimums[2] = 1;
        sera.batchModifyWhitelistedTokens(tokens, true, minimums);
        vm.stopBroadcast();
    }

    /// @dev Give a local actor fixture tokens and move them into Vault custody.
    /// @param key Private key of `user`, used for approve and deposit broadcasts.
    /// @param user Vault account to credit.
    /// @param token Fixture ERC-20 to mint and deposit.
    /// @param sera Core contract that forwards the deposit into Vault.
    /// @param amount Raw 18-decimal token amount.
    function _mintAndDeposit(uint256 key, address user, MockStableCoin token, Sera sera, uint256 amount) private {
        vm.startBroadcast(key);
        // Production users would receive tokens elsewhere; fixture tokens are
        // permissionlessly mintable solely to make this local demo self-contained.
        token.mint(user, amount);
        // Vault is the ERC-20 spender. depositFund then invokes Vault.deposit.
        IERC20(address(token)).approve(address(sera.vault()), amount);
        sera.depositFund(address(token), user, amount);
        vm.stopBroadcast();
    }

    /// @dev Execute one signed order pair in two fills and verify fill tracking.
    /// @param sera Core matching engine.
    /// @param executorKey Authorized transaction submitter.
    /// @param takerKey Key used to sign the taker's order.
    /// @param makerKey Key used to sign the maker's order.
    /// @param taker Buyer of USDC / seller of USDT.
    /// @param maker Seller of USDC / buyer of USDT.
    /// @param usdt Input asset.
    /// @param usdc Output asset.
    /// @param expiry Shared order expiry timestamp.
    function _directAndPartialMatch(Sera sera, uint256 executorKey, uint256 takerKey, uint256 makerKey, address taker, address maker, MockStableCoin usdt, MockStableCoin usdc, uint48 expiry) private {
        // Both parties sign a 200 USDT <-> 400 USDC limit order. The executor
        // settles it twice at 100/200, demonstrating reusable signed orders.
        Order memory buy = _order(taker, address(usdt), address(usdc), 200 * UNIT, 400 * UNIT, 11, expiry, taker, 0);
        Order memory sell = _order(maker, address(usdc), address(usdt), 400 * UNIT, 200 * UNIT, 12, expiry, maker, 0);
        MatchData memory m = MatchData(buy, _signOrder(takerKey, buy, sera), 100 * UNIT, sell, _signOrder(makerKey, sell, sera), 200 * UNIT);
        vm.startBroadcast(executorKey);
        sera.matchOrders(m, block.timestamp + 1 hours);
        sera.matchOrders(m, block.timestamp + 1 hours);
        vm.stopBroadcast();
        require(sera.filledAmount(_orderHash(buy)) == 200 * UNIT, "partial-fill tracking failed");
        // A non-zero recipient pays the output directly to the wallet, rather
        // than crediting the recipient's Vault ledger.
        require(IERC20(address(usdc)).balanceOf(taker) == 400 * UNIT, "direct match payout failed");
        summary.directUsdtSpent = 200 * UNIT;
        summary.directUsdcReceivedExternally = 400 * UNIT;
        console2.log("1. direct match and partial fill: OK");
    }

    /// @dev Demonstrate best-effort batch failure reporting and atomic execution.
    /// @param sera Core contract providing the EIP-712 domain for order signatures.
    /// @param batcher Wrapper exposing both batch execution modes.
    /// @param executorKey Authorized batch submitter.
    /// @param takerKey Key used to sign taker orders.
    /// @param makerKey Key used to sign maker orders.
    /// @param taker USDT-selling actor.
    /// @param maker USDC-selling actor.
    /// @param usdt Input asset.
    /// @param usdc Output asset.
    /// @param expiry Order expiry timestamp.
    function _batchModes(Sera sera, SeraBatcher batcher, uint256 executorKey, uint256 takerKey, uint256 makerKey, address taker, address maker, MockStableCoin usdt, MockStableCoin usdc, uint48 expiry) private {
        // The second match intentionally has an invalid maker signature. The
        // best-effort batch should settle index 0 and return bit 1 in failedMask.
        MatchData[] memory matches = new MatchData[](2);
        matches[0] = _pair(sera, takerKey, makerKey, taker, maker, address(usdt), address(usdc), 50 * UNIT, 100 * UNIT, 21, 22, expiry);
        matches[1] = _pair(sera, takerKey, makerKey, taker, maker, address(usdt), address(usdc), 50 * UNIT, 100 * UNIT, 23, 24, expiry);
        matches[1].signature1 = hex"deadbeef";
        vm.startBroadcast(executorKey);
        uint256 failedMask = batcher.batchMatchOrders(matches, block.timestamp + 1 hours);
        vm.stopBroadcast();
        require(failedMask == 2, "best-effort failed-mask mismatch");
        summary.batchFailedMask = failedMask;

        // Atomic mode is all-or-nothing. This one-element successful case keeps
        // the walkthrough broadcastable while exercising its distinct entrypoint.
        MatchData[] memory atomicMatches = new MatchData[](1);
        atomicMatches[0] = _pair(sera, takerKey, makerKey, taker, maker, address(usdt), address(usdc), 50 * UNIT, 100 * UNIT, 25, 26, expiry);
        vm.startBroadcast(executorKey);
        batcher.batchMatchOrdersAtomic(atomicMatches, block.timestamp + 1 hours);
        vm.stopBroadcast();
        summary.batchSuccessfulInput = 50 * UNIT;
        console2.log("2. best-effort and atomic batches: OK");
    }

    /// @dev Route one taker authorization through USDT -> USDC -> SGD.
    /// @param sera Core engine used for domain separation and balance checks.
    /// @param sor Trusted router which validates the signed route envelope.
    /// @param executorKey Authorized SOR transaction submitter.
    /// @param takerKey Key that signs the single route envelope.
    /// @param makerOneKey Key for the first-leg maker order.
    /// @param makerTwoKey Key for the second-leg maker order.
    /// @param taker Route initiator and final Vault recipient.
    /// @param makerOne USDC liquidity provider.
    /// @param makerTwo SGD liquidity provider.
    /// @param usdt Route input token.
    /// @param usdc Intermediate token.
    /// @param sgd Route output token.
    /// @param expiry Intent and maker-order expiry timestamp.
    function _sorRoute(Sera sera, SeraSOR sor, uint256 executorKey, uint256 takerKey, uint256 makerOneKey, uint256 makerTwoKey, address taker, address makerOne, address makerTwo, MockStableCoin usdt, MockStableCoin usdc, MockStableCoin sgd, uint48 expiry) private {
        vm.startBroadcast(takerKey);
        // Earlier direct matches deliver their USDT input to makers externally;
        // mint a fresh local-only wallet balance to demonstrate signed SOR funding.
        usdt.mint(taker, 100 * UNIT);
        IERC20(address(usdt)).approve(address(sor), 100 * UNIT);
        vm.stopBroadcast();
        // Leg 1 sends its USDC output to Sera. SOR holds that intermediate
        // balance in memory, so it never needs a Vault deposit/withdraw round trip.
        MatchData[] memory route = new MatchData[](2);
        Order memory legOne = _order(taker, address(usdt), address(usdc), 100 * UNIT, 200 * UNIT, 31, expiry, address(sera), 100 * UNIT);
        Order memory makerOne = _order(makerOne, address(usdc), address(usdt), 200 * UNIT, 100 * UNIT, 32, expiry, makerOne, 0);
        route[0] = MatchData(legOne, "", 100 * UNIT, makerOne, _signOrder(makerOneKey, makerOne, sera), 200 * UNIT);
        // A zero recipient credits the terminal output to the taker's Vault ledger,
        // which leaves an asset available for the withdrawal demonstrations below.
        Order memory legTwo = _order(taker, address(usdc), address(sgd), 200 * UNIT, 300 * UNIT, 33, expiry, address(0), 0);
        Order memory makerTwo = _order(makerTwo, address(sgd), address(usdc), 300 * UNIT, 200 * UNIT, 34, expiry, makerTwo, 0);
        // `type(uint256).max` means "consume all intermediate USDC". The
        // zero recipient on the final leg credits SGD to the taker's Vault ledger.
        route[1] = MatchData(legTwo, "", type(uint256).max, makerTwo, _signOrder(makerTwoKey, makerTwo, sera), 300 * UNIT);
        // This is the sole taker signature for the full route. It commits the
        // maximum USDT spend, minimum SGD output, wallet pull, recipient and UUID.
        IntentParams memory intent = IntentParams(taker, address(usdt), address(sgd), 100 * UNIT, 300 * UNIT, address(0), 100 * UNIT, 35, expiry);
        vm.startBroadcast(executorKey);
        sor.executeIntent(route, _signIntent(takerKey, intent, sera), intent, 3, 0, "");
        vm.stopBroadcast();
        require(sera.vault().balanceOf(address(sgd), taker) >= 300 * UNIT, "SOR output missing");
        require(sera.isIntentUuidUsed(taker, 35), "SOR replay protection missing");
        summary.sorWalletFunding = 100 * UNIT;
        summary.sorIntermediateUsdc = 200 * UNIT;
        summary.sorSgdCreditedToVault = 300 * UNIT;
        summary.sorUuidConsumed = true;
        console2.log("3. two-hop SOR with signed wallet funding: OK");
    }

    /// @dev Demonstrate both withdrawal authorization models using the SOR output.
    /// @param sera Core contract that owns withdrawal state.
    /// @param executorKey Key used to co-sign and submit the instant withdrawal.
    /// @param takerKey Key used to authorize the instant withdrawal and request the delayed one.
    /// @param executor Account holding EXECUTOR_ROLE.
    /// @param taker Vault owner and withdrawal recipient.
    /// @param sgd Asset withdrawn from the taker's Vault balance.
    function _instantAndDelayedWithdraw(Sera sera, uint256 executorKey, uint256 takerKey, address executor, address taker, MockStableCoin sgd) private {
        address[] memory tokens = new address[](1); tokens[0] = address(sgd);
        uint256[] memory amounts = new uint256[](1); amounts[0] = 50 * UNIT;
        WithdrawIntent memory intent = WithdrawIntent(taker, tokens, amounts, taker, block.timestamp + 1 days, 41);
        // An instant withdrawal needs matching EIP-712 approvals from the user
        // and an account holding EXECUTOR_ROLE; either party may submit it.
        bytes32 digest = _withdrawDigest(intent, sera);
        vm.startBroadcast(executorKey);
        sera.executeInstantWithdrawDualSig(intent, _signDigest(takerKey, digest), executor, _signDigest(executorKey, digest));
        vm.stopBroadcast();
        require(IERC20(address(sgd)).balanceOf(taker) == 50 * UNIT, "instant withdrawal failed");
        summary.instantWithdrawal = 50 * UNIT;
        // The first emergencyWithdraw call records the requested amount and
        // starts its 7,200-block delay. The shell wrapper mines and executes it.
        vm.startBroadcast(takerKey);
        sera.emergencyWithdraw(address(sgd), 1 * UNIT);
        vm.stopBroadcast();
        (, uint256 requestedAmount) = sera.withdrawRequests(taker, address(sgd));
        require(requestedAmount == 1 * UNIT, "delayed withdrawal request failed");
        summary.delayedWithdrawal = requestedAmount;
        console2.log("4. instant dual-signature and delayed-withdraw request: OK");
    }

    /// @dev Pause deposits, prove the guard rejects one, then restore operation.
    /// @param sera Core contract whose global pause state is exercised.
    /// @param deployerKey Key holding PAUSER_ROLE in this local fixture.
    /// @param taker User used in the rejected deposit probe.
    /// @param usdt Whitelisted token passed to the rejected deposit call.
    function _pauseCheck(Sera sera, uint256 deployerKey, address taker, MockStableCoin usdt) private {
        vm.startBroadcast(deployerKey); sera.pause(); vm.stopBroadcast();
        // Keep the expected-revert probe outside a broadcast segment: a reverted
        // transaction is useful to demonstrate the guard but must not be included
        // in Foundry's transaction bundle for a successful walkthrough.
        (bool ok,) = address(sera).call(abi.encodeCall(sera.depositFund, (address(usdt), taker, UNIT)));
        require(!ok, "pause did not block deposit");
        summary.pauseBlockedDeposit = true;
        vm.startBroadcast(deployerKey); sera.unpause(); vm.stopBroadcast();
        console2.log("5. pause and unpause guard: OK");
    }

    /// @dev Print a single operator-facing summary after every assertion has passed.
    /// The values show where assets moved (Vault vs. wallet) and what authority
    /// was required at every potentially privileged step.
    function _printSummary(Sera sera, SeraBatcher batcher, SeraSOR sor, MockStableCoin usdt, MockStableCoin usdc, MockStableCoin sgd, address taker, address makerOne, address makerTwo) private view {
        console2.log("\n================ SERA V2 LOCAL EXPERIENCE SUMMARY ================");
        console2.log("Contracts");
        console2.log("  Sera", address(sera));
        console2.log("  Vault", address(sera.vault()));
        console2.log("  SeraSOR", address(sor));
        console2.log("  SeraBatcher", address(batcher));

        console2.log("\n1) Vault funding (before trading)");
        console2.log("  taker USDT in Vault", summary.initialTakerUsdtInVault / UNIT);
        console2.log("  maker 1 USDC in Vault", summary.initialMakerUsdcInVault / UNIT);
        console2.log("  maker 2 SGD in Vault", summary.initialMakerSgdInVault / UNIT);

        console2.log("\n2) Direct signed order + partial fills");
        console2.log("  taker spent USDT from Vault", summary.directUsdtSpent / UNIT);
        console2.log("  taker received USDC externally", summary.directUsdcReceivedExternally / UNIT);
        console2.log("  result: one EIP-712 order was filled twice by EXECUTOR_ROLE");

        console2.log("\n3) Batch execution");
        console2.log("  best-effort failedMask", summary.batchFailedMask);
        console2.log("  interpretation: bit 1 = the deliberately invalid second match failed");
        console2.log("  atomic batch successful input", summary.batchSuccessfulInput / UNIT);

        console2.log("\n4) SOR route (single taker signature)");
        console2.log("  route: USDT -> USDC -> SGD");
        console2.log("  wallet-funded USDT", summary.sorWalletFunding / UNIT);
        console2.log("  transient intermediate USDC", summary.sorIntermediateUsdc / UNIT);
        console2.log("  SGD credited to taker Vault", summary.sorSgdCreditedToVault / UNIT);
        console2.log("  route UUID consumed", summary.sorUuidConsumed);
        console2.log("  result: executor chose the legs; signed max-input/min-output bounds remained enforced");

        console2.log("\n5) Withdrawal authority");
        console2.log("  instant SGD withdrawal (user + executor signatures)", summary.instantWithdrawal / UNIT);
        console2.log("  delayed SGD withdrawal requested (user only)", summary.delayedWithdrawal / UNIT);
        console2.log("  result: the shell wrapper mines 7,200 Anvil blocks then completes the delayed path");

        console2.log("\n6) Emergency controls");
        console2.log("  paused deposit was blocked", summary.pauseBlockedDeposit);
        console2.log("  result: admin paused then restored normal operation");

        console2.log("\nFinal Vault balances (whole tokens)");
        console2.log("  taker USDT", sera.vault().balanceOf(address(usdt), taker) / UNIT);
        console2.log("  taker USDC", sera.vault().balanceOf(address(usdc), taker) / UNIT);
        console2.log("  taker SGD", sera.vault().balanceOf(address(sgd), taker) / UNIT);
        console2.log("  maker 1 USDC", sera.vault().balanceOf(address(usdc), makerOne) / UNIT);
        console2.log("  maker 2 SGD", sera.vault().balanceOf(address(sgd), makerTwo) / UNIT);
        console2.log("====================================================================\n");
    }

    /// @dev Build complementary orders and their EIP-712 signatures for a direct match.
    /// @param sera Core contract defining the EIP-712 domain.
    /// @param takerKey Signing key for the first order.
    /// @param makerKey Signing key for the complementary order.
    /// @param taker First order's owner.
    /// @param maker Second order's owner.
    /// @param from Asset sold by `taker`.
    /// @param to Asset received by `taker`.
    /// @param input Amount `taker` sells.
    /// @param output Amount `taker` receives.
    /// @param takerUuid Replay-protection identifier for the first order.
    /// @param makerUuid Replay-protection identifier for the second order.
    /// @param expiry Shared order expiry timestamp.
    /// @return MatchData Fully signed, complementary fill instruction.
    function _pair(Sera sera, uint256 takerKey, uint256 makerKey, address taker, address maker, address from, address to, uint256 input, uint256 output, uint256 takerUuid, uint256 makerUuid, uint48 expiry) private view returns (MatchData memory) {
        // A normal pair is symmetric: each order's input token is the other's
        // output token. Different UUIDs prevent an order from matching itself.
        Order memory a = _order(taker, from, to, input, output, takerUuid, expiry, taker, 0);
        Order memory b = _order(maker, to, from, output, input, makerUuid, expiry, maker, 0);
        return MatchData(a, _signOrder(takerKey, a, sera), input, b, _signOrder(makerKey, b, sera), output);
    }

    /// @dev Construct an Order with zero fees for a deterministic local demo.
    /// @param user Owner and signer of the order.
    /// @param from Token sold by the order.
    /// @param to Token received by the order.
    /// @param fromAmount Maximum sale amount.
    /// @param toAmount Minimum desired output.
    /// @param uuid Per-user replay-protection value.
    /// @param expiry Order expiry timestamp.
    /// @param recipient Non-zero pays externally; zero credits the user's Vault ledger.
    /// @param initialDeposit Wallet amount committed for a SOR route, otherwise zero.
    /// @return Order Populated unsigned order.
    function _order(address user, address from, address to, uint256 fromAmount, uint256 toAmount, uint256 uuid, uint48 expiry, address recipient, uint256 initialDeposit) private pure returns (Order memory) {
        return Order(user, expiry, 0, recipient, from, to, fromAmount, toAmount, initialDeposit, uuid);
    }

    /// @dev Create a standard 65-byte ECDSA EIP-712 signature for an Order.
    /// @param key Signer's local private key.
    /// @param order Order fields included in the typed-data hash.
    /// @param sera Contract supplying the current EIP-712 domain separator.
    /// @return bytes Signature encoded as r || s || v.
    function _signOrder(uint256 key, Order memory order, Sera sera) private view returns (bytes memory) {
        // Recreate the exact EIP-712 struct hash used by Sera, then sign the
        // typed-data digest with Foundry's local account key.
        bytes32 structHash = keccak256(abi.encode(ORDER_TYPEHASH, order.user, order.expiration, order.feeBps, order.recipient, order.fromToken, order.toToken, order.fromAmount, order.toAmount, order.initialDepositAmount, order.uuid));
        return _signDigest(key, keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @dev Create the one EIP-712 authorization required for an entire SOR route.
    /// @param key Taker's local private key.
    /// @param intent Signed max-input, min-output, recipient, deposit, UUID and expiry bounds.
    /// @param sera Contract supplying the EIP-712 domain separator.
    /// @return bytes Signature encoded as r || s || v.
    function _signIntent(uint256 key, IntentParams memory intent, Sera sera) private view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(INTENT_TYPEHASH, intent.taker, intent.inputToken, intent.outputToken, intent.maxInputAmount, intent.minOutputAmount, intent.recipient, intent.initialDepositAmount, intent.uuid, intent.deadline));
        return _signDigest(key, keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @dev Calculate the EIP-712 digest that user and executor co-sign for withdrawal.
    /// @param intent Exact token/amount arrays, recipient, deadline and UUID to authorize.
    /// @param sera Contract supplying the EIP-712 domain separator.
    /// @return bytes32 Digest accepted by executeInstantWithdrawDualSig.
    function _withdrawDigest(WithdrawIntent memory intent, Sera sera) private view returns (bytes32) {
        // EIP-712 hashes dynamic arrays before including them in the enclosing
        // struct. This walkthrough uses one token, but follows the canonical rule.
        bytes32 tokenHash = keccak256(abi.encode(intent.tokens[0]));
        bytes32 amountHash = keccak256(abi.encode(intent.amounts[0]));
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_INTENT_TYPEHASH, intent.user, tokenHash, amountHash, intent.recipient, intent.deadline, intent.uuid));
        return keccak256(abi.encodePacked("\x19\x01", sera.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Sign an already domain-separated digest with Foundry's cheatcode.
    /// @param key Local private key.
    /// @param digest EIP-712 digest to sign.
    /// @return bytes Standard 65-byte r || s || v signature.
    function _signDigest(uint256 key, bytes32 digest) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Reproduce Sera's order struct hash for the partial-fill assertion.
    /// @param order Order whose filledAmount mapping key is required.
    /// @return bytes32 Struct hash used by Sera as the filled-amount key.
    function _orderHash(Order memory order) private pure returns (bytes32) {
        return keccak256(abi.encode(ORDER_TYPEHASH, order.user, order.expiration, order.feeBps, order.recipient, order.fromToken, order.toToken, order.fromAmount, order.toAmount, order.initialDepositAmount, order.uuid));
    }
}
