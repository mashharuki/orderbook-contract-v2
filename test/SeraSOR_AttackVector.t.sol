// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_AttackVector_Test
 * @dev Tests for attack vectors, edge cases, and boundary conditions:
 *      - Replay attacks (same route twice)
 *      - Sentinel abuse (drain via sentinel)
 *      - Maker/taker impersonation
 *      - Spread distribution edge cases
 *      - Split topology with sentinel
 *      - Zero-amount boundary conditions
 */
contract SeraSOR_AttackVector_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;
    MockStableCoin public btc;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;
    address public attacker;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");
        attacker = makeAddr("attacker");

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
            user: user,
            fromToken: fromToken,
            toToken: toToken,
            fromAmount: fromAmount,
            toAmount: toAmount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user,
            expiration: uint48(block.timestamp + 1 days),
            uuid: uuid
        });
    }

    // ============ 1. REPLAY ATTACK ============

    /// @notice Same route signature can't be replayed after taker's order is fully filled
    function test_Replay_FullyFilledTakerOrder_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera); // 2x so maker isn't the blocker

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 2000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Execute first time — should succeed
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Replay — intent already consumed, should revert
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        vm.prank(executor);
        vm.expectRevert(Sera.UuidAlreadyUsed.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 2. NON-EXECUTOR ATTACK ============

    /// @notice Non-executor can't call executeRoute
    function test_NonExecutor_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Attacker tries to call executeRoute
        vm.prank(attacker);
        vm.expectRevert();
        // Will revert with Unauthorized(attacker, EXECUTOR_ROLE)
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 3. DIRECT settleRoutedLeg BYPASS ============

    /// @notice Attacker tries to call settleRoutedLeg directly (bypassing SeraSOR)
    function test_DirectSettleRoutedLeg_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData memory m = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);

        // Attacker tries to call settleRoutedLeg directly
        vm.prank(attacker);
        vm.expectRevert(Sera.RouterNotTrusted.selector);
        sera.settleRoutedLeg(m, 1000 ether, false, 1000 ether);
    }

    // ============ 4. TAKER IMPERSONATION ============

    /// @notice Can't create a route with a different taker in one of the legs
    function test_TakerImpersonation_MixedUsers_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Leg 1: taker is the real taker
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: "taker" is actually the attacker — trying to steal maker2's output
        Order memory fakeTakerLeg2 = _makeOrder(attacker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(fakeTakerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector); // Different user in leg 2
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 5. PAUSED CONTRACT ============

    /// @notice Route execution blocked when Sera is paused
    function test_PausedContract_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Pause the contract
        vm.prank(owner);
        sera.pause();

        vm.prank(executor);
        vm.expectRevert(SeraBase.SeraPaused.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 6. DEADLINE EXPIRY ============

    /// @notice Route execution blocked after deadline
    function test_ExpiredDeadline_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);

        // Use a short deadline that will expire after warp
        uint48 shortDeadline = uint48(block.timestamp + 50);
        uint256 nonce = 999;
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, nonce, shortDeadline, sera);

        // Warp past deadline
        vm.warp(block.timestamp + 100);

        vm.prank(executor);
        vm.expectRevert(MatchExpired.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, nonce, shortDeadline), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 7. SPREAD DISTRIBUTION — ALL TO PROTOCOL ============

    /// @notice 100% spread to protocol — taker and maker get no bonus
    function test_SpreadDistribution_AllToProtocol() public {
        // Set 100% spread to protocol
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Create spread: taker offers 1000 USDC for 8 ETH, maker offers 10 ETH for 800 USDC
        // matchAmount0 = 1000, matchAmount1 = 10
        // executionValue0 = Ceil(1000 * 8/1000) = 8 ETH (what taker expects)
        // executionValue1 = Ceil(10 * 800/10) = 800 USDC (what maker expects)
        // totalSpread0 = 1000 - 800 = 200 USDC spread
        // totalSpread1 = 10 - 8 = 2 ETH spread
        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Protocol should capture 100% of spread
        // USDC spread: 200 → all to protocol
        // ETH spread: 2 → all to protocol
        assertEq(sera.vault().balanceOf(address(usdc), owner), 200 ether, "Protocol captured 200 USDC spread");
        assertEq(sera.vault().balanceOf(address(eth), owner), 2 ether, "Protocol captured 2 ETH spread");

        // Taker receives exactly executionValue0 = 8 ETH (no bonus)
        assertEq(eth.balanceOf(taker), 8 ether, "Taker received exactly 8 ETH (no taker bonus)");
        // Maker receives exactly executionValue1 = 800 USDC (no bonus)
        assertEq(usdc.balanceOf(maker1), 800 ether, "Maker received exactly 800 USDC (no maker bonus)");
    }

    // ============ 8. SPREAD DISTRIBUTION — ALL TO TAKER/MAKER ============

    /// @notice 100% spread to taker — protocol and maker get nothing
    function test_SpreadDistribution_AllToTaker() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 10000, 0, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // In the SOR routed path:
        // matchAmount0 = 1000, taker has 1000 in vault, entire 1000 pulled
        // adjustedEV1 = executionValue1 + takerBonus0 = 800 + 200 = 1000
        // makerReceives = 1000 - 0 = 1000 USDC (maker gets everything)
        // Taker vault USDC = 1000 - 1000 = 0
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Taker spent entire 1000 USDC");
        // Maker receives 1000 USDC (bonus absorbed into maker payout)
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker received all 1000 USDC");
        // Taker gets 8 ETH (executionValue0 with all takerBps, makerBonus1=0)
        assertEq(eth.balanceOf(taker), 8 ether, "Taker received 8 ETH");
        // Maker keeps 2 ETH in vault (implicit Token 1 rebate)
        assertEq(sera.vault().balanceOf(address(eth), maker1), 2 ether, "Maker retained 2 ETH spread");

        // Protocol gets nothing
        assertEq(sera.vault().balanceOf(address(usdc), owner), 0, "Protocol got no USDC spread");
        assertEq(sera.vault().balanceOf(address(eth), owner), 0, "Protocol got no ETH spread");
    }

    // ============ 9. EMPTY ROUTE ============

    /// @notice Empty route array reverts
    function test_EmptyRoute_Reverts() public {
        MatchData[] memory matches = new MatchData[](0);
        vm.prank(executor);
        vm.expectRevert(SeraSOR.EmptyRoute.selector);
        sor.executeIntent(matches, bytes(""), IntentParams(taker, address(0), address(0), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(1), 0, bytes(""));
    }

    // ============ 10. TOO MANY LEGS ============

    /// @notice Route with > MAX_ROUTE_LEGS reverts
    function test_TooManyLegs_Reverts() public {
        MatchData[] memory matches = new MatchData[](21);
        vm.prank(executor);
        vm.expectRevert(SeraSOR.TooManyLegs.selector);
        sor.executeIntent(matches, bytes(""), IntentParams(taker, address(0), address(0), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(1), 0, bytes(""));
    }

    // ============ 11. BLACKLISTED MAKER ============

    /// @notice Blacklisted maker can't participate in route
    function test_BlacklistedMaker_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Blacklist maker (vault admin is `owner` via Vault(owner) constructor)
        Vault v = sera.vault();
        vm.prank(owner);
        v.setBlacklisted(maker1, true);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, maker1));
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 12. EXPIRED MAKER ORDER ============

    /// @notice Expired maker order in route reverts
    function test_ExpiredMakerOrder_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);
        makerOrder.expiration = uint48(block.timestamp); // Expired (<=)

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(Sera.OrderExpired.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 13. INSUFFICIENT MAKER BALANCE ============

    /// @notice Maker without enough vault balance reverts
    function test_InsufficientMakerBalance_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 5 ether, sera); // Only 5, needs 10

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(Sera.InsufficientVaultBalance.selector);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 14. REMOVED: MAKER WITH ROUTEHASH ============
    // routeHash field was removed from Order struct. Maker orders are validated via EIP-712 signature only.

    // ============ 15. VAULT SOLVENCY AFTER COMPLEX ROUTE ============

    /// @notice Vault solvency maintained after a 3-leg route with fees and spread
    function test_VaultSolvency_ComplexRoute() public {
        uint256 initialVaultUSDC = 5000 ether;
        uint256 initialVaultETH = 20 ether;
        uint256 initialVaultBTC = 5 ether;

        _mintAndDeposit(taker, address(usdc), initialVaultUSDC, sera);
        _mintAndDeposit(maker1, address(eth), initialVaultETH, sera);
        _mintAndDeposit(maker2, address(btc), initialVaultBTC, sera);

        // Simple: taker 1000 USDC → 10 ETH → 1 BTC
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Solvency check: vault's actual ERC20 balance >= sum of all user ledger balances
        Vault v = sera.vault();

        // USDC: taker sold 1000, maker1 received 1000
        uint256 totalLedgerUSDC = v.balanceOf(address(usdc), taker)
            + v.balanceOf(address(usdc), maker1)
            + v.balanceOf(address(usdc), maker2)
            + v.balanceOf(address(usdc), owner);
        uint256 actualUSDC = usdc.balanceOf(address(v));
        assertGe(actualUSDC, totalLedgerUSDC, "Vault solvent: USDC actual >= ledger sum");

        // ETH: maker1 sold 10, maker2 received 10
        uint256 totalLedgerETH = v.balanceOf(address(eth), taker)
            + v.balanceOf(address(eth), maker1)
            + v.balanceOf(address(eth), maker2)
            + v.balanceOf(address(eth), owner);
        uint256 actualETH = eth.balanceOf(address(v));
        assertGe(actualETH, totalLedgerETH, "Vault solvent: ETH actual >= ledger sum");

        // BTC: taker received 1, maker2 sold 1
        uint256 totalLedgerBTC = v.balanceOf(address(btc), taker)
            + v.balanceOf(address(btc), maker1)
            + v.balanceOf(address(btc), maker2)
            + v.balanceOf(address(btc), owner);
        uint256 actualBTC = btc.balanceOf(address(v));
        assertGe(actualBTC, totalLedgerBTC, "Vault solvent: BTC actual >= ledger sum");

        // No tokens stuck in Sera
        assertEq(usdc.balanceOf(address(sera)), 0, "No USDC stuck in Sera");
        assertEq(eth.balanceOf(address(sera)), 0, "No ETH stuck in Sera");
        assertEq(btc.balanceOf(address(sera)), 0, "No BTC stuck in Sera");
    }
}
