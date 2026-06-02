/*
 * Certora specification for Sera.
 *
 * This spec deliberately verifies small, security-relevant contracts:
 * - settlement math and filledAmount state transitions through SeraCertoraHarness
 * - authorization guards on executor/router/admin entrypoints
 * - replay protection state transitions
 * - delayed-withdrawal request/execute state-machine edges
 *
 * It is not a blanket proof of the protocol. Signatures, token behavior, and
 * multi-leg routing are still modeled at their boundaries and need separate
 * specs/tests.
 */

methods {
    function filledAmount(bytes32) external returns (uint256) envfree;
    function isUuidExecuted(address, uint256) external returns (bool) envfree;
    function isIntentUuidUsed(address, uint256) external returns (bool) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function EXECUTOR_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;
    function PAUSER_ROLE() external returns (bytes32) envfree;
    function trustedRouter() external returns (address) envfree;
    function treasury() external returns (address) envfree;
    function paused() external returns (bool) envfree;
    function WITHDRAW_DELAY_BLOCKS() external returns (uint32) envfree;
    function WITHDRAW_EXPIRATION_BLOCKS() external returns (uint32) envfree;
    function MAX_EXPIRATION() external returns (uint256) envfree;
    function withdrawRequests(address, address) external returns (uint256, uint256) envfree;

    function certoraBpsDenominator() external returns (uint256) envfree;
    function certoraHashOrder(SeraCertoraHarness.Order) external returns (bytes32) envfree;
    function certoraExecutionValues(SeraCertoraHarness.MatchData, uint256, uint256) external returns (uint256, uint256) envfree;
    function certoraValidateOrderCommon(SeraCertoraHarness.Order, bytes32, uint256) external returns (uint256);
    function certoraSlippageShares() external returns (uint64, uint64, uint64, uint64) envfree;
    function certoraSlippageSharesValid() external returns (bool) envfree;
    function certoraTokenConfig(address) external returns (bool, uint248) envfree;
    function certoraVaultBalanceOf(address, address) external returns (uint256) envfree;

    function _.balanceOf(address, address) external => DISPATCHER(true);
    function _.deposit(address, address, uint256) external => DISPATCHER(true);
    function _.withdraw(address, address, uint256, address) external => DISPATCHER(true);
    function _.transferLedger(address, address, address, uint256) external => DISPATCHER(true);
    function _.creditLedger(address, address, uint256) external => DISPATCHER(true);
    function _.isBlacklisted(address) external => DISPATCHER(true);
}

definition BPS_DENOMINATOR() returns uint256 = 100000000000000;
definition ONE_YEAR_SECONDS() returns uint256 = 31536000;
definition nonzero(address a) returns bool = a != 0;
definition canAdd(uint256 a, uint256 b) returns bool = a <= max_uint256 - b;
definition validSlippageShares(uint64 makerShare, uint64 takerShare, uint64 protocolShare, uint64 totalBps) returns bool =
    totalBps != 0 && to_mathint(makerShare) + to_mathint(takerShare) + to_mathint(protocolShare) == to_mathint(totalBps);

invariant withdrawDelayConstant()
    WITHDRAW_DELAY_BLOCKS() == 7200;

invariant withdrawExpirationConstant()
    WITHDRAW_EXPIRATION_BLOCKS() == 14400;

invariant maxExpirationConstant()
    MAX_EXPIRATION() == ONE_YEAR_SECONDS();

invariant slippageSharesStayValid()
    certoraSlippageSharesValid();

rule executionValuesRespectBothLimitPrices(SeraCertoraHarness.MatchData m, uint256 effectiveAmount0, uint256 effectiveAmount1) {
    require m.order0.fromAmount > 0;
    require m.order1.fromAmount > 0;
    require canAdd(effectiveAmount0, 0);
    require canAdd(effectiveAmount1, 0);

    uint256 executionValue0;
    uint256 executionValue1;
    (executionValue0, executionValue1) = certoraExecutionValues@withrevert(m, effectiveAmount0, effectiveAmount1);

    assert !lastReverted => effectiveAmount1 >= executionValue0,
        "order1 input must cover order0 limit output";
    assert !lastReverted => effectiveAmount0 >= executionValue1,
        "order0 input must cover order1 limit output";
}

rule calculateSettlementUpdatesFillAndKeepsBounds(
    env e,
    SeraCertoraHarness.MatchData m,
    uint256 executionValue0,
    uint256 executionValue1,
    uint256 effectiveAmount0,
    uint256 effectiveAmount1,
    bytes32 orderHash0,
    bytes32 orderHash1
) {
    require orderHash0 != orderHash1;
    require m.order0.fromAmount > 0;
    require m.order1.fromAmount > 0;
    require m.order0.feeBps <= BPS_DENOMINATOR();
    require m.order1.feeBps <= BPS_DENOMINATOR();
    require effectiveAmount0 >= executionValue1;
    require effectiveAmount1 >= executionValue0;
    require canAdd(filledAmount(orderHash0), effectiveAmount0);
    require canAdd(filledAmount(orderHash1), effectiveAmount1);
    require filledAmount(orderHash0) + effectiveAmount0 <= m.order0.fromAmount;
    require filledAmount(orderHash1) + effectiveAmount1 <= m.order1.fromAmount;

    uint64 makerShare;
    uint64 takerShare;
    uint64 protocolShare;
    uint64 totalBps;
    (makerShare, takerShare, protocolShare, totalBps) = certoraSlippageShares();
    require validSlippageShares(makerShare, takerShare, protocolShare, totalBps);

    uint256 filled0Before = filledAmount(orderHash0);
    uint256 filled1Before = filledAmount(orderHash1);

    uint256 protocolFee0;
    uint256 protocolFee1;
    uint256 protocolTake0;
    uint256 protocolTake1;
    uint256 resultExecutionValue0;
    uint256 resultExecutionValue1;
    bool order0FullyFilled;
    bool order1FullyFilled;

    (
        protocolFee0,
        protocolFee1,
        protocolTake0,
        protocolTake1,
        resultExecutionValue0,
        resultExecutionValue1,
        order0FullyFilled,
        order1FullyFilled
    ) = certoraCalculateSettlement(e, m, executionValue0, executionValue1, effectiveAmount0, effectiveAmount1, orderHash0, orderHash1);

    assert filledAmount(orderHash0) == filled0Before + effectiveAmount0,
        "settlement must increment order0 filled amount by effective amount";
    assert filledAmount(orderHash1) == filled1Before + effectiveAmount1,
        "settlement must increment order1 filled amount by effective amount";
    assert filledAmount(orderHash0) <= m.order0.fromAmount,
        "settlement must not overfill order0";
    assert filledAmount(orderHash1) <= m.order1.fromAmount,
        "settlement must not overfill order1";
    assert resultExecutionValue0 >= executionValue0,
        "order0 receipt before fee may only increase with spread share";
    assert resultExecutionValue1 >= executionValue1,
        "order1 receipt before fee may only increase with spread share";
    assert protocolTake0 >= protocolFee0,
        "token0 protocol take must include at least the protocol fee";
    assert protocolTake1 >= protocolFee1,
        "token1 protocol take must include at least the protocol fee";
    assert order0FullyFilled <=> filledAmount(orderHash0) >= m.order0.fromAmount,
        "order0 full-fill flag must match post-fill state";
    assert order1FullyFilled <=> filledAmount(orderHash1) >= m.order1.fromAmount,
        "order1 full-fill flag must match post-fill state";
}

rule validateOrderCommonRejectsExpiredOrder(env e, SeraCertoraHarness.Order order, bytes32 orderHash, uint256 matchAmount) {
    require order.expiration <= e.block.timestamp;

    certoraValidateOrderCommon@withrevert(e, order, orderHash, matchAmount);

    assert lastReverted,
        "expired orders must revert in common validation";
}

rule validateOrderCommonRejectsOverfill(env e, SeraCertoraHarness.Order order, bytes32 orderHash, uint256 matchAmount) {
    require matchAmount > 0;
    require canAdd(filledAmount(orderHash), matchAmount);
    require filledAmount(orderHash) + matchAmount > order.fromAmount;

    certoraValidateOrderCommon@withrevert(e, order, orderHash, matchAmount);

    assert lastReverted,
        "orders must not validate if matchAmount overfills fromAmount";
}

rule validateOrderCommonFirstFillRejectsBadFee(env e, SeraCertoraHarness.Order order, bytes32 orderHash, uint256 matchAmount) {
    require filledAmount(orderHash) == 0;
    require matchAmount > 0;
    require order.expiration > e.block.timestamp;
    require canAdd(filledAmount(orderHash), matchAmount);
    require matchAmount <= order.fromAmount;
    require order.fromAmount > 0;
    require order.toAmount > 0;
    require e.block.timestamp <= max_uint256 - MAX_EXPIRATION();
    require order.expiration <= e.block.timestamp + MAX_EXPIRATION();
    require order.feeBps > BPS_DENOMINATOR();

    certoraValidateOrderCommon@withrevert(e, order, orderHash, matchAmount);

    assert lastReverted,
        "first fill must reject feeBps above denominator";
}

rule matchOrdersRequiresExecutor(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    bool senderIsExecutor = hasRole(EXECUTOR_ROLE(), e.msg.sender);

    matchOrders@withrevert(e, m, deadline);

    assert !senderIsExecutor => lastReverted,
        "non-executor must not match orders";
}

rule matchOrdersRejectsPaused(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    require paused();

    matchOrders@withrevert(e, m, deadline);

    assert lastReverted,
        "paused Sera must reject matchOrders";
}

rule matchOrdersRejectsExpiredDeadline(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    require e.block.timestamp > deadline;

    matchOrders@withrevert(e, m, deadline);

    assert lastReverted,
        "matchOrders deadline must be enforced";
}

rule matchOrdersRejectsTokenMismatch(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    require m.order0.fromToken != m.order1.toToken || m.order1.fromToken != m.order0.toToken;

    matchOrders@withrevert(e, m, deadline);

    assert lastReverted,
        "mismatched token symmetry must revert";
}

rule matchOrdersRejectsSameToken(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    require m.order0.fromToken == m.order1.toToken;
    require m.order1.fromToken == m.order0.toToken;
    require m.order0.fromToken == m.order0.toToken;

    matchOrders@withrevert(e, m, deadline);

    assert lastReverted,
        "same-token matches must revert";
}

rule matchOrdersRejectsSelfMatch(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    require m.order0.fromToken == m.order1.toToken;
    require m.order1.fromToken == m.order0.toToken;
    require m.order0.fromToken != m.order0.toToken;

    bytes32 orderHash0 = certoraHashOrder(m.order0);
    bytes32 orderHash1 = certoraHashOrder(m.order1);
    require orderHash0 == orderHash1;

    matchOrders@withrevert(e, m, deadline);

    assert lastReverted,
        "matching an order against itself must revert";
}

rule matchOrdersSuccessUpdatesFilledAmounts(env e, SeraCertoraHarness.MatchData m, uint256 deadline) {
    bytes32 orderHash0 = certoraHashOrder(m.order0);
    bytes32 orderHash1 = certoraHashOrder(m.order1);
    uint256 filled0Before = filledAmount(orderHash0);
    uint256 filled1Before = filledAmount(orderHash1);
    require canAdd(filled0Before, m.matchAmount0);
    require canAdd(filled1Before, m.matchAmount1);

    matchOrders@withrevert(e, m, deadline);

    bool matchSucceeded = !lastReverted;
    uint256 filled0After = filledAmount(orderHash0);
    uint256 filled1After = filledAmount(orderHash1);

    assert matchSucceeded => filled0After == filled0Before + m.matchAmount0,
        "successful matchOrders must add matchAmount0 to order0 filled amount";
    assert matchSucceeded => filled1After == filled1Before + m.matchAmount1,
        "successful matchOrders must add matchAmount1 to order1 filled amount";
    assert matchSucceeded => filled0After <= m.order0.fromAmount,
        "successful matchOrders must not overfill order0";
    assert matchSucceeded => filled1After <= m.order1.fromAmount,
        "successful matchOrders must not overfill order1";
}

rule setSlippageSharesOnlyAcceptsValidSplit(env e, uint64 makerShare, uint64 takerShare, uint64 protocolShare, uint64 totalBps) {
    bool senderIsAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    bool validSplit = validSlippageShares(makerShare, takerShare, protocolShare, totalBps);

    setSlippageShares@withrevert(e, makerShare, takerShare, protocolShare, totalBps);

    assert (!senderIsAdmin || !validSplit) => lastReverted,
        "invalid split or non-admin caller must revert";

    if (!lastReverted) {
        uint64 makerAfter;
        uint64 takerAfter;
        uint64 protocolAfter;
        uint64 totalAfter;
        (makerAfter, takerAfter, protocolAfter, totalAfter) = certoraSlippageShares();

        assert makerAfter == makerShare,
            "maker share must update atomically";
        assert takerAfter == takerShare,
            "taker share must update atomically";
        assert protocolAfter == protocolShare,
            "protocol share must update atomically";
        assert totalAfter == totalBps,
            "totalBps must update atomically";
    }

    assert true,
        "setSlippageShares rule completed";
}

rule onlyAdminCanSetTrustedRouter(env e, address router) {
    bool senderIsAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    setTrustedRouter@withrevert(e, router);

    bool setSucceeded = !lastReverted;
    assert (!senderIsAdmin || router == 0) => !setSucceeded,
        "non-admin or zero router must revert";

    address routerAfter = trustedRouter();
    assert setSucceeded => routerAfter == router,
        "trusted router must update atomically on success";
}

rule onlyAdminCanSetTreasury(env e, address newTreasury) {
    bool senderIsAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    setTreasury@withrevert(e, newTreasury);

    bool setSucceeded = !lastReverted;
    assert (!senderIsAdmin || newTreasury == 0) => !setSucceeded,
        "non-admin or zero treasury must revert";

    address treasuryAfter = treasury();
    assert setSucceeded => treasuryAfter == newTreasury,
        "treasury must update atomically on success";
}

rule onlyPauserCanPause(env e) {
    bool senderIsPauser = hasRole(PAUSER_ROLE(), e.msg.sender);

    pause@withrevert(e);

    assert !senderIsPauser => lastReverted,
        "non-pauser must not pause";
}

rule consumeIntentUuidRequiresTrustedRouter(env e, address user, uint256 uuid) {
    address router = trustedRouter();

    consumeIntentUuid@withrevert(e, user, uuid);

    bool consumeSucceeded = !lastReverted;
    assert e.msg.sender != router => !consumeSucceeded,
        "only trusted router may consume intent UUIDs";

    bool usedAfter = isIntentUuidUsed(user, uuid);
    assert consumeSucceeded => usedAfter,
        "successful consumeIntentUuid must mark UUID used";
}

rule consumeIntentUuidCannotReplay(env e1, env e2, address user, uint256 uuid) {
    require trustedRouter() != 0;
    require e1.msg.sender == trustedRouter();
    require e2.msg.sender == trustedRouter();

    consumeIntentUuid@withrevert(e1, user, uuid);

    if (!lastReverted) {
        consumeIntentUuid@withrevert(e2, user, uuid);

        assert lastReverted,
            "consumed intent UUID must not be consumable again";
    }

    assert true,
        "consumeIntentUuid replay rule completed";
}

rule instantWithdrawRejectsExecutedUuid(
    env e,
    SeraCertoraHarness.WithdrawIntent intent,
    bytes userSignature,
    address executor,
    bytes executorSignature
) {
    require isUuidExecuted(intent.user, intent.uuid);

    executeInstantWithdrawDualSig@withrevert(e, intent, userSignature, executor, executorSignature);

    assert lastReverted,
        "instant withdraw must reject already executed UUID";
}

rule instantWithdrawMarksUuidOnSuccess(
    env e,
    SeraCertoraHarness.WithdrawIntent intent,
    bytes userSignature,
    address executor,
    bytes executorSignature
) {
    bool wasExecuted = isUuidExecuted(intent.user, intent.uuid);

    executeInstantWithdrawDualSig@withrevert(e, intent, userSignature, executor, executorSignature);

    bool withdrawSucceeded = !lastReverted;
    bool executedAfter = isUuidExecuted(intent.user, intent.uuid);

    assert withdrawSucceeded => !wasExecuted,
        "successful instant withdraw cannot start from an executed UUID";
    assert withdrawSucceeded => executedAfter,
        "successful instant withdraw must consume its UUID";
}

rule emergencyWithdrawRejectsZeroInputs(env e, address token, uint256 amount) {
    require token == 0 || amount == 0;

    emergencyWithdraw@withrevert(e, token, amount);

    assert lastReverted,
        "emergencyWithdraw must reject zero token or zero amount";
}

rule emergencyWithdrawRequestRecordsBlockAndAmount(env e, address token, uint256 amount) {
    require token != 0;
    require amount > 0;
    require certoraVaultBalanceOf(token, e.msg.sender) >= amount;

    uint256 requestBlockBefore;
    uint256 requestAmountBefore;
    (requestBlockBefore, requestAmountBefore) = withdrawRequests(e.msg.sender, token);
    require requestBlockBefore == 0 || requestBlockBefore <= max_uint256 - WITHDRAW_EXPIRATION_BLOCKS();
    require requestBlockBefore == 0 || e.block.number > requestBlockBefore + WITHDRAW_EXPIRATION_BLOCKS();

    emergencyWithdraw@withrevert(e, token, amount);

    bool requestSucceeded = !lastReverted;
    uint256 requestBlockAfter;
    uint256 requestAmountAfter;
    (requestBlockAfter, requestAmountAfter) = withdrawRequests(e.msg.sender, token);

    assert requestSucceeded => requestBlockAfter == e.block.number,
        "new emergency withdraw request must record current block";
    assert requestSucceeded => requestAmountAfter == amount,
        "new emergency withdraw request must record requested amount";
}

rule emergencyWithdrawRejectsEarlyExecution(env e, address token, uint256 amount) {
    require token != 0;
    require amount > 0;

    uint256 requestBlock;
    uint256 requestAmount;
    (requestBlock, requestAmount) = withdrawRequests(e.msg.sender, token);
    require requestBlock != 0;
    require requestBlock <= e.block.number;
    require requestBlock <= max_uint256 - WITHDRAW_DELAY_BLOCKS();
    require e.block.number < requestBlock + WITHDRAW_DELAY_BLOCKS();

    emergencyWithdraw@withrevert(e, token, amount);

    assert lastReverted,
        "emergency withdraw execution must respect delay";
}

rule emergencyWithdrawRejectsAmountAboveRequest(env e, address token, uint256 amount) {
    require token != 0;
    require amount > 0;

    uint256 requestBlock;
    uint256 requestAmount;
    (requestBlock, requestAmount) = withdrawRequests(e.msg.sender, token);
    require requestBlock != 0;
    require requestBlock <= max_uint256 - WITHDRAW_EXPIRATION_BLOCKS();
    require e.block.number >= requestBlock + WITHDRAW_DELAY_BLOCKS();
    require e.block.number <= requestBlock + WITHDRAW_EXPIRATION_BLOCKS();
    require amount > requestAmount;

    emergencyWithdraw@withrevert(e, token, amount);

    assert lastReverted,
        "emergency withdraw execution must reject amount above request";
}

rule emergencyWithdrawDeletesRequestOnSuccessfulExecution(env e, address token, uint256 amount) {
    require token != 0;
    require amount > 0;

    uint256 requestBlock;
    uint256 requestAmount;
    (requestBlock, requestAmount) = withdrawRequests(e.msg.sender, token);
    require requestBlock != 0;
    require requestBlock <= max_uint256 - WITHDRAW_EXPIRATION_BLOCKS();
    require e.block.number >= requestBlock + WITHDRAW_DELAY_BLOCKS();
    require e.block.number <= requestBlock + WITHDRAW_EXPIRATION_BLOCKS();
    require amount <= requestAmount;

    emergencyWithdraw@withrevert(e, token, amount);

    bool withdrawSucceeded = !lastReverted;
    uint256 requestBlockAfter;
    uint256 requestAmountAfter;
    (requestBlockAfter, requestAmountAfter) = withdrawRequests(e.msg.sender, token);

    assert withdrawSucceeded => requestBlockAfter == 0,
        "successful emergency withdraw execution must delete request block";
    assert withdrawSucceeded => requestAmountAfter == 0,
        "successful emergency withdraw execution must delete request amount";
}

rule settleRoutedLegRequiresTrustedRouter(
    env e,
    SeraCertoraHarness.MatchData m,
    uint256 takerVaultPull,
    bool holdTakerOutput,
    uint256 effectiveMatchAmount0
) {
    address router = trustedRouter();

    settleRoutedLeg@withrevert(e, m, takerVaultPull, holdTakerOutput, effectiveMatchAmount0);

    assert e.msg.sender != router => lastReverted,
        "only trusted router may settle routed legs";
}

rule settleRoutedLegRejectsOverPull(
    env e,
    SeraCertoraHarness.MatchData m,
    uint256 takerVaultPull,
    bool holdTakerOutput,
    uint256 effectiveMatchAmount0
) {
    require trustedRouter() != 0;
    require e.msg.sender == trustedRouter();
    require takerVaultPull > effectiveMatchAmount0;

    settleRoutedLeg@withrevert(e, m, takerVaultPull, holdTakerOutput, effectiveMatchAmount0);

    assert lastReverted,
        "routed settlement must reject takerVaultPull above effective amount";
}

rule settleRoutedLegSuccessUpdatesFilledAmounts(
    env e,
    SeraCertoraHarness.MatchData m,
    uint256 takerVaultPull,
    bool holdTakerOutput,
    uint256 effectiveMatchAmount0
) {
    bytes32 takerHash = certoraHashOrder(m.order0);
    bytes32 makerHash = certoraHashOrder(m.order1);
    uint256 takerFilledBefore = filledAmount(takerHash);
    uint256 makerFilledBefore = filledAmount(makerHash);
    require canAdd(takerFilledBefore, effectiveMatchAmount0);
    require canAdd(makerFilledBefore, m.matchAmount1);

    settleRoutedLeg@withrevert(e, m, takerVaultPull, holdTakerOutput, effectiveMatchAmount0);

    bool routedSucceeded = !lastReverted;
    uint256 takerFilledAfter = filledAmount(takerHash);
    uint256 makerFilledAfter = filledAmount(makerHash);

    assert routedSucceeded => takerFilledAfter == takerFilledBefore + effectiveMatchAmount0,
        "successful routed leg must fill taker by effective amount";
    assert routedSucceeded => makerFilledAfter == makerFilledBefore + m.matchAmount1,
        "successful routed leg must fill maker by matchAmount1";
    assert routedSucceeded => takerFilledAfter <= m.order0.fromAmount,
        "successful routed leg must not overfill taker";
    assert routedSucceeded => makerFilledAfter <= m.order1.fromAmount,
        "successful routed leg must not overfill maker";
}
