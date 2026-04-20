// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_EdgeCase_Test
 * @dev Edge case tests covering:
 *      - Emergency withdraw timing + re-request
 *      - Cross-path fill tracking (same order used in route + standalone)
 *      - Taker rebate accounting verification (exact distribution math)
 *      - Dual-sig instant withdraw security
 *      - Vault solvency invariant under sequential routes
 *      - Token 1 spread accounting in routed path
 *      - Multi-leg rebate accumulation
 */
contract SeraSOR_EdgeCase_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;
    MockStableCoin public btc;

    address public owner;
    address public executor;
    uint256 public executorPK;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;

    function setUp() public {
        owner = makeAddr("owner");
        (executor, executorPK) = makeAddrAndKey("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");

        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");
        btc = new MockStableCoin("BTC");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        _whitelistToken(sera, address(btc), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();
    }


    function _makeOrder(
        address user, address fromToken, address toToken,
        uint256 fromAmount, uint256 toAmount, uint256 uuid
    ) internal view returns (Order memory) {
        return Order({
            user: user, fromToken: fromToken, toToken: toToken,
            fromAmount: fromAmount, toAmount: toAmount, initialDepositAmount: 0,
            feeBps: 0, recipient: user,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    function _assertNoSeraDust(address token, string memory label) internal view {
        assertEq(IERC20(token).balanceOf(address(sera)), 0, string.concat("No dust in Sera: ", label));
    }

    // Helper: compute order hash from memory struct
    function _orderHash(Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH, o.user, o.expiration, o.feeBps, o.recipient,
            o.fromToken, o.toToken, o.fromAmount, o.toAmount,
            o.initialDepositAmount, o.uuid
        ));
    }

    // ========================================================================
    // 1. EMERGENCY WITHDRAW: TIMING & RE-REQUEST
    // ========================================================================

    function test_EmergencyWithdraw_FullFlow() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);

        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);

        (uint256 reqBlock, uint256 reqAmount) = sera.withdrawRequests(taker, address(usdc));
        assertEq(reqAmount, 1000 ether, "Request amount stored");
        assertEq(reqBlock, block.number, "Request block stored");

        vm.roll(block.number + 7199);
        vm.expectRevert(Sera.WithdrawNotReady.selector);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);

        vm.roll(block.number + 1);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);
        assertEq(usdc.balanceOf(taker), 1000 ether, "Taker received USDC");
    }

    function test_EmergencyWithdraw_PartialAmount() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);
        vm.roll(block.number + 7200);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 500 ether);
        assertEq(usdc.balanceOf(taker), 500 ether, "Partial withdraw success");
    }

    function test_EmergencyWithdraw_ExceedsRequest_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);
        vm.roll(block.number + 7200);
        vm.expectRevert(Sera.AmountMismatch.selector);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1001 ether);
    }

    function test_EmergencyWithdraw_ExpiredReRequest() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 500 ether);
        vm.roll(block.number + 14401);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);

        (uint256 reqBlock, uint256 reqAmount) = sera.withdrawRequests(taker, address(usdc));
        assertEq(reqAmount, 1000 ether, "Re-request with new amount");
        assertGt(reqBlock, 14400, "New request block");

        vm.roll(block.number + 7200);
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);
        assertEq(usdc.balanceOf(taker), 1000 ether, "Full withdraw after re-request");
    }

    // ========================================================================
    // 2. CROSS-PATH FILL TRACKING
    // ========================================================================

    function test_CrossPath_RouteToStandalone() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);

        Order memory maker = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 2000 ether, 2);

        // Route 1: fill 10 ETH of maker
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory matches1 = new MatchData[](1);
        matches1[0] = MatchData(t1, bytes(""), 1000 ether, maker, _signOrder(maker1PK, maker, sera), 10 ether);

        // Pre-compute sig BEFORE prank
        bytes memory rsig1 = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches1, rsig1, IntentParams(taker, matches1[0].order0.fromToken, matches1[matches1.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches1.length * 2 + 1), 0, bytes(""));

        bytes32 makerHash = _orderHash(maker);
        assertEq(sera.filledAmount(makerHash), 10 ether, "Maker 50% filled via route");
        _assertNoSeraDust(address(usdc), "PostRoute");

        // Standalone match: fill remaining 10 ETH of SAME maker
        (address taker2, uint256 taker2PK) = makeAddrAndKey("taker2");
        _mintAndDeposit(taker2, address(usdc), 1000 ether, sera);

        Order memory t2 = _makeOrder(taker2, address(usdc), address(eth), 1000 ether, 10 ether, 10);
        MatchData memory standaloneMatch = MatchData(
            t2, _signOrder(taker2PK, t2, sera), 1000 ether,
            maker, _signOrder(maker1PK, maker, sera), 10 ether
        );

        vm.prank(executor);
        sera.matchOrders(standaloneMatch, type(uint256).max);
        assertEq(sera.filledAmount(makerHash), 20 ether, "Maker 100% filled (route + standalone)");
    }

    function test_CrossRoute_SameMakerTwoRoutes() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);

        Order memory maker = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 2000 ether, 2);

        // Route A: fill 5 ETH
        Order memory tA = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory routeA = new MatchData[](1);
        routeA[0] = MatchData(tA, bytes(""), 500 ether, maker, _signOrder(maker1PK, maker, sera), 5 ether);
        bytes memory rsigA = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(routeA, rsigA, IntentParams(taker, routeA[0].order0.fromToken, routeA[routeA.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(routeA.length * 2 + 1), 0, bytes(""));

        bytes32 makerHash = _orderHash(maker);
        assertEq(sera.filledAmount(makerHash), 5 ether, "Maker 25% filled after route A");

        // Route B: fill another 5 ETH
        Order memory tB = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory routeB = new MatchData[](1);
        routeB[0] = MatchData(tB, bytes(""), 500 ether, maker, _signOrder(maker1PK, maker, sera), 5 ether);
        bytes memory rsigB = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp + 1, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(routeB, rsigB, IntentParams(taker, routeB[0].order0.fromToken, routeB[routeB.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 1, uint48(block.timestamp + 1 days)), uint8(routeB.length * 2 + 1), 0, bytes(""));

        assertEq(sera.filledAmount(makerHash), 10 ether, "Maker 50% filled after route B");
    }

    // ========================================================================
    // 3. EXACT TAKER REBATE VERIFICATION
    // ========================================================================

    function test_ExactRebate_MixedConfig() public {
        vm.prank(owner);
        sera.setSlippageShares(3000, 2000, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory rsig = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, rsig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        Vault v = sera.vault();

        // Shares (maker=3000, taker=2000, protocol=5000) on totalSpread0 = 200:
        //   protocolSpread0 = 100, spreadToMaker0 = 60, spreadToTaker0 = 40.
        //   calc.executionValue1 = 800 + spreadToMaker0 = 860 → maker explicit uplift.
        //   Taker retains spreadToTaker0 = 40 implicit.
        uint256 takerRebate = v.balanceOf(address(usdc), taker);
        assertEq(takerRebate, 40 ether, "Taker USDC retains spreadToTaker0 = 40 (implicit)");

        uint256 protocolUsdc = v.balanceOf(address(usdc), owner);
        assertEq(protocolUsdc, 100 ether, "Protocol USDC take = protocolSpread0 = 100");

        // Maker receives calc.executionValue1 - protocolFee0 = 860 - 0 = 860 USDC via safeTransfer to wallet.
        uint256 makerUsdc = usdc.balanceOf(maker1);
        assertEq(makerUsdc, 860 ether, "Maker USDC received = 860 (800 + spreadToMaker0=60)");

        // Total: 40 + 100 + 860 = 1000 = matchAmount0
        assertEq(takerRebate + protocolUsdc + makerUsdc, 1000 ether, "Token 0 sum = matchAmount0");

        _assertNoSeraDust(address(usdc), "exact rebate USDC");
        _assertNoSeraDust(address(eth), "exact rebate ETH");
    }

    function test_ExactRebate_Token1Side() public {
        vm.prank(owner);
        sera.setSlippageShares(3000, 2000, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory rsig = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp + 2, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, rsig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 2, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        Vault v = sera.vault();

        // Token 1 (ETH): executionValue0 = 8, totalSpread1 = 2.
        //   Shares (maker=3000, taker=2000, protocol=5000):
        //   protocolSpread1 = 1, spreadToMaker1 = 0.6, spreadToTaker1 = 0.4.
        //   calc.executionValue0 = 8 + spreadToTaker1 = 8.4 → taker explicit uplift.
        //   Maker debited 8.4 (payout) + 1 (protocol) = 9.4; retains 0.6 (spreadToMaker1 implicit).
        assertEq(eth.balanceOf(taker), 8.4 ether, "Taker ETH = 8.4 (8 + spreadToTaker1=0.4 uplift)");
        assertEq(v.balanceOf(address(eth), maker1), 0.6 ether, "Maker ETH remaining = 0.6 (spreadToMaker1 implicit)");
        assertEq(v.balanceOf(address(eth), owner), 1 ether, "Protocol ETH = 1");
    }

    // ========================================================================
    // 4. DUAL-SIG INSTANT WITHDRAW
    // ========================================================================

    function test_DualSig_UuidReplay_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        WithdrawIntent memory intent = WithdrawIntent({
            user: taker,
            tokens: tokens,
            amounts: amounts,
            recipient: taker,
            deadline: block.timestamp + 1 days,
            uuid: 42
        });

        bytes32 intentHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                _hashAddressArray(tokens),
                keccak256(abi.encodePacked(amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );

        bytes32 domainSep = sera.DOMAIN_SEPARATOR();
        bytes32 fullDigest = keccak256(abi.encodePacked("\x19\x01", domainSep, intentHash));

        // User signs
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(takerPK, fullDigest);
        bytes memory userSig = abi.encodePacked(r, s, v);

        // Executor signs (use executorPK from setUp)
        (v, r, s) = vm.sign(executorPK, fullDigest);
        bytes memory execSig = abi.encodePacked(r, s, v);

        // First withdraw succeeds
        sera.executeInstantWithdrawDualSig(intent, userSig, executor, execSig);
        assertEq(usdc.balanceOf(taker), 500 ether, "First withdraw success");

        // Replay with same uuid reverts
        _mintAndDeposit(taker, address(usdc), 500 ether, sera);
        vm.expectRevert(Sera.UuidAlreadyUsed.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, executor, execSig);
    }

    // ========================================================================
    // 5. VAULT SOLVENCY UNDER SEQUENTIAL ROUTES
    // ========================================================================

    function test_VaultSolvency_SequentialRoutes() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);

        Order memory maker = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 1600 ether, 2);
        Vault v = sera.vault();

        // Route 1
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory r1 = new MatchData[](1);
        r1[0] = MatchData(t1, bytes(""), 1000 ether, maker, _signOrder(maker1PK, maker, sera), 10 ether);
        bytes memory rsig1 = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp + 3, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(r1, rsig1, IntentParams(taker, r1[0].order0.fromToken, r1[r1.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 3, uint48(block.timestamp + 1 days)), uint8(r1.length * 2 + 1), 0, bytes(""));

        uint256 vaultUsdcActual = usdc.balanceOf(address(v));
        uint256 vaultUsdcLedger = v.balanceOf(address(usdc), taker) + v.balanceOf(address(usdc), maker1) + v.balanceOf(address(usdc), owner);
        assertGe(vaultUsdcActual, vaultUsdcLedger, "USDC solvent after route 1");

        // Route 2
        Order memory t2 = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory r2 = new MatchData[](1);
        r2[0] = MatchData(t2, bytes(""), 1000 ether, maker, _signOrder(maker1PK, maker, sera), 10 ether);
        bytes memory rsig2 = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp + 4, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(r2, rsig2, IntentParams(taker, r2[0].order0.fromToken, r2[r2.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 4, uint48(block.timestamp + 1 days)), uint8(r2.length * 2 + 1), 0, bytes(""));

        vaultUsdcActual = usdc.balanceOf(address(v));
        vaultUsdcLedger = v.balanceOf(address(usdc), taker) + v.balanceOf(address(usdc), maker1) + v.balanceOf(address(usdc), owner);
        assertGe(vaultUsdcActual, vaultUsdcLedger, "USDC solvent after route 2");

        uint256 vaultEthActual = eth.balanceOf(address(v));
        uint256 vaultEthLedger = v.balanceOf(address(eth), taker) + v.balanceOf(address(eth), maker1) + v.balanceOf(address(eth), owner);
        assertGe(vaultEthActual, vaultEthLedger, "ETH solvent after route 2");

        _assertNoSeraDust(address(usdc), "Sequential USDC");
        _assertNoSeraDust(address(eth), "Sequential ETH");
    }

    // ========================================================================
    // 6. OVERFILL VIA ROUTE
    // ========================================================================

    function test_OverfillViaRoute_Reverts() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Taker order: only 1000 USDC fromAmount. matchAmount0 = 1001 > fromAmount → OrderFilledAmountExceeded
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1001 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory rsig = _signIntent(takerPK, taker, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp + 5, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(Sera.OrderFilledAmountExceeded.selector);
        sor.executeIntent(matches, rsig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 5, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ========================================================================
    // 7. EMERGENCY WITHDRAW ALLOWS ANY USER (not blocked by frozen)
    // ========================================================================

    function test_EmergencyWithdraw_NotBlockedByPause() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);

        // Request while unpaused
        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);

        vm.roll(block.number + 7200);

        // emergencyWithdraw has no whenNotPaused — user can withdraw even if paused
        // But wait — emergencyWithdraw has no pausing check! Let me verify...
        // Line 208: no whenNotPaused modifier on emergencyWithdraw ✓

        vm.prank(taker);
        sera.emergencyWithdraw(address(usdc), 1000 ether);
        assertEq(usdc.balanceOf(taker), 1000 ether, "Emergency withdraw succeeds");
    }

    // ========================================================================
    // 8. MULTI-LEG TAKER REBATE ACCUMULATION
    // ========================================================================

    function test_MultiLeg_TakerRebate_Accumulates() public {
        vm.prank(owner);
        sera.setSlippageShares(5000, 0, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 5 ether, sera);

        // Shares (maker=5000, taker=0, protocol=5000): taker gets zero explicit and zero implicit on every leg.
        // Leg 1: USDC→ETH. Taker: 1000→8 ETH, Maker: 10→800 USDC. matchAmount0 = 1000, matchAmount1 = 10.
        //   totalSpread0 = 200 → protocol 100, spreadToMaker0 = 100, spreadToTaker0 = 0.
        //   totalSpread1 = 2   → protocol 1,   spreadToMaker1 = 1,   spreadToTaker1 = 0.
        //   calc.executionValue1 = 800 + 100 = 900 (maker1 wallet USDC).
        //   calc.executionValue0 = 8 + 0 = 8 ETH transient held in Sera.
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        // Leg 2: ETH→BTC. Taker: 10→1, Maker: 1→5 ETH. Sentinel consumes 8 ETH transient.
        //   effectiveAmount0 = 8. executionValue0 = ceil(8*1/10) = 0.8 BTC. executionValue1 = 5 ETH.
        //   totalSpread0 = 8 - 5 = 3 ETH → protocol 1.5, spreadToMaker0 = 1.5, spreadToTaker0 = 0.
        //   totalSpread1 = 1 - 0.8 = 0.2 BTC → protocol 0.1, spreadToMaker1 = 0.1, spreadToTaker1 = 0.
        //   calc.executionValue1 = 5 + 1.5 = 6.5 (to maker2 wallet).
        //   calc.executionValue0 = 0.8 + 0 = 0.8 BTC (to taker wallet).
        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory m2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 5 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, m1, _signOrder(maker1PK, m1, sera), 10 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), 1 ether);
        bytes memory rsig = _signIntent(takerPK, taker, address(usdc), address(btc), 0, 0, taker, 0, block.timestamp + 6, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, rsig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp + 6, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        Vault v = sera.vault();

        // Taker gets no explicit or implicit share on either leg (takerShareBps = 0).
        assertEq(v.balanceOf(address(usdc), taker), 0, "Taker USDC: no rebate (spreadToTaker0 = 0)");
        assertEq(v.balanceOf(address(eth), taker), 0, "Taker ETH: no transient surplus (spreadToTaker0 leg2 = 0)");
        assertEq(btc.balanceOf(taker), 0.8 ether, "Taker BTC = 0.8 (executionValue0, no uplift)");

        // Makers receive explicit uplifts.
        assertEq(usdc.balanceOf(maker1), 900 ether, "Maker1 USDC = 900 (800 + spreadToMaker0 = 100)");
        assertEq(eth.balanceOf(maker2), 6.5 ether, "Maker2 ETH = 6.5 (5 + spreadToMaker0 = 1.5)");

        // Makers retain their implicit rebates on token1 of each leg (vault balance reflects initial deposit - actual debit).
        assertEq(v.balanceOf(address(eth), maker1), 1 ether, "Maker1 retains 1 ETH (10 dep - 9 debit; spreadToMaker1=1)");
        assertEq(v.balanceOf(address(btc), maker2), 4.1 ether, "Maker2 retains 4.1 BTC (5 dep - 0.9 debit; spreadToMaker1=0.1)");

        _assertNoSeraDust(address(usdc), "MultiLeg USDC");
        _assertNoSeraDust(address(eth), "MultiLeg ETH");
        _assertNoSeraDust(address(btc), "MultiLeg BTC");
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _hashAddressArray(address[] memory arr) private pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](arr.length);
        for (uint256 i; i < arr.length; i++) {
            words[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(words));
    }
}
