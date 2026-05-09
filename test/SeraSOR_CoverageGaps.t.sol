// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_CoverageGaps
 * @notice Tests covering 3 identified gaps in SOR coverage:
 *  Diamond with positive slippage on intermediate legs (exact amounts verified)
 *  Diamond with wallet funding (initialDepositAmount > 0)
 *  Diamond where both terminal legs deliver output token to taker (convergent diamond)
 */
contract SeraSOR_CoverageGaps is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public v;

    MockStableCoin public A;
    MockStableCoin public B;
    MockStableCoin public C;
    MockStableCoin public D;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public m1; uint256 public m1PK;
    address public m2; uint256 public m2PK;
    address public m3; uint256 public m3PK;
    address public m4; uint256 public m4PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (m1, m1PK) = makeAddrAndKey("m1");
        (m2, m2PK) = makeAddrAndKey("m2");
        (m3, m3PK) = makeAddrAndKey("m3");
        (m4, m4PK) = makeAddrAndKey("m4");

        A = new MockStableCoin("A");
        B = new MockStableCoin("B");
        C = new MockStableCoin("C");
        D = new MockStableCoin("D");

        sera = _deploySera(owner);
        v = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(A), true, 1);
        _whitelistToken(sera, address(B), true, 1);
        _whitelistToken(sera, address(C), true, 1);
        _whitelistToken(sera, address(D), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        sera.setTreasury(owner);
        // 25% maker, 25% taker, 50% protocol
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        vm.stopPrank();
    }

    // ---- Helpers ----

    function _oFull(
        address user, address from, address to, uint256 fromAmt, uint256 toAmt,
        uint256 uuid, uint48 feeBps, address recipient
    ) internal view returns (Order memory) {
        return Order({
            user: user, fromToken: from, toToken: to,
            fromAmount: fromAmt, toAmount: toAmt, initialDepositAmount: 0,
            feeBps: feeBps, recipient: recipient,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    uint256 private _execNonce = 5000;

    function _exec(MatchData[] memory matches, address _r) internal {
        uint256 nonce = _execNonce++;
        uint256 _d = matches[0].order0.initialDepositAmount;
        address _in = matches[0].order0.fromToken;
        address _out = matches[matches.length - 1].order0.toToken;
        uint48 _dl = uint48(block.timestamp + 1 days);
        bytes memory sig = _signIntent(takerPK, taker, _in, _out, 0, 0, _r, _d, nonce, _dl, sera);
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(taker, _in, _out, 0, 0, _r, _d, nonce, _dl), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    function _assertNoDust(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(sera)), 0, "dust in Sera");
    }

    function _assertSolvent(address token) internal view {
        uint256 totalLedger = v.balanceOf(token, taker)
            + v.balanceOf(token, m1) + v.balanceOf(token, m2)
            + v.balanceOf(token, m3) + v.balanceOf(token, m4)
            + v.balanceOf(token, owner);
        assertGe(IERC20(token).balanceOf(address(v)), totalLedger, "vault insolvent");
    }

    // ====================================================================
    //  Diamond with positive slippage on INTERMEDIATE legs.
    //
    //  Topology: A ---> B ---> D  (branch 1)
    //            A ---> C ---> D  (branch 2)
    //
    //  Intermediate legs (B->D, C->D) have positive slippage:
    //  - Maker offers MORE than taker's minimum
    //  - The surplus should be split per slippage shares
    //  - Exact amounts are verified (not just > 0 / solvency)
    //
    //  All legs zero fees to isolate spread behavior.
    //  Slippage: 25% maker, 25% taker, 50% protocol
    // ====================================================================
    function test_Gap1_Diamond_IntermediatePositiveSlippage() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Leg 1: 1000 A -> B (hold in Sera). Zero spread: taker wants 500 B, maker offers exactly 500 B
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 0, m1);

        // Leg 2: 1000 A -> C (hold in Sera). Zero spread: taker wants 400 C, maker offers exactly 400 C
        Order memory t2 = _oFull(taker, address(A), address(C), 1000 ether, 400 ether, 3, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(A), 400 ether, 1000 ether, 4, 0, m2);

        // Leg 3: sentinel B -> D. Positive slippage: taker wants 100 D for 500 B, but maker gives 200 D for 500 B
        // Spread = 200 - 100 = 100 D. Split: 25 maker, 25 taker, 50 protocol
        Order memory t3 = _oFull(taker, address(B), address(D), 500 ether, 100 ether, 5, 0, taker);
        Order memory mk3 = _oFull(m3, address(D), address(B), 200 ether, 500 ether, 6, 0, m3);

        // Leg 4: sentinel C -> D. Positive slippage: taker wants 80 D for 400 C, but maker gives 160 D for 400 C
        // Spread = 160 - 80 = 80 D. Split: 20 maker, 20 taker, 40 protocol
        Order memory t4 = _oFull(taker, address(C), address(D), 400 ether, 80 ether, 7, 0, taker);
        Order memory mk4 = _oFull(m4, address(D), address(C), 160 ether, 400 ether, 8, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), 1000 ether, mk2, _signOrder(m2PK, mk2, sera), 400 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 200 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 160 ether);

        uint256 takerDBefore = D.balanceOf(taker);
        uint256 protocolDBefore = v.balanceOf(address(D), owner);

        _exec(matches, taker);

        uint256 takerDReceived = D.balanceOf(taker) - takerDBefore;
        uint256 protocolDReceived = v.balanceOf(address(D), owner) - protocolDBefore;

        // Leg 3 spread on D side:
        //   executionValue0 = ceil(500 * 100 / 500) = 100 (what taker expects)
        //   effectiveAmount1 = 200 (what maker gives)
        //   totalSpread1 = 200 - 100 = 100
        //   protocolSpread = floor(100 * 5000 / 10000) = 50
        //   makerSpread = floor(100 * 2500 / 10000) = 25
        //   takerSpread = 100 - 50 - 25 = 25
        //   executionValue0_adj = 100 + 25 (makerSpread1) = 125
        //   takerReceives = executionValue0_adj - protocolFee1 = 125 - 0 = 125

        // Leg 4 spread on D side:
        //   executionValue0 = ceil(400 * 80 / 400) = 80
        //   effectiveAmount1 = 160
        //   totalSpread1 = 160 - 80 = 80
        //   protocolSpread = floor(80 * 5000 / 10000) = 40
        //   makerSpread = floor(80 * 2500 / 10000) = 20
        //   takerSpread = 80 - 40 - 20 = 20
        //   executionValue0_adj = 80 + 20 = 100
        //   takerReceives = 100 - 0 = 100

        // Total taker D = 125 + 100 = 225
        assertEq(takerDReceived, 225 ether, "Taker received exact 225 D (125 leg3 + 100 leg4)");

        // Total protocol D = 50 + 40 = 90
        assertEq(protocolDReceived, 90 ether, "Protocol received exact 90 D (50 leg3 + 40 leg4)");

        // No dust, all solvent
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
        _assertSolvent(address(B));
        _assertSolvent(address(C));
        _assertSolvent(address(D));
    }

    // ====================================================================
    //  Diamond with wallet funding (initialDepositAmount > 0).
    //
    //  Same diamond topology but taker pays from wallet, not vault.
    //  Leg 1 uses initialDepositAmount to pull A from taker's wallet.
    //  Remaining legs use transient (sentinel) balances.
    // ====================================================================
    function test_Gap2_Diamond_WalletFunded() public {
        // Taker has A in wallet, NOT in vault
        _mintInWallet(taker, address(A), 2000 ether);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Taker approves SOR to pull from wallet
        vm.prank(taker);
        A.approve(address(sor), type(uint256).max);

        // Leg 1: 1000 A -> B (wallet funded, hold in Sera)
        Order memory t1 = Order({
            user: taker, fromToken: address(A), toToken: address(B),
            fromAmount: 1000 ether, toAmount: 500 ether, initialDepositAmount: 1000 ether,
            feeBps: 0, recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days), uuid: 10
        });
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 11, 0, m1);

        // Leg 2: 1000 A -> C (wallet funded, hold in Sera)
        // IMPORTANT: The first leg already consumed the 1000 ether wallet deposit.
        // The second leg's fromToken is A, so it needs A from somewhere.
        // Since only the first leg can pull from wallet, leg 2 must use vault.
        // BUT taker has no vault A. So we restructure: both first-leg pulls come from wallet.
        //
        // Actually, the SOR only does initialDepositAmount on matches[0]. For 2 input legs,
        // we need all 2000 A pulled in leg 0. Let's restructure as:
        //   Leg 0: 2000 A -> A (self, impossible) -- NO. We need a different approach.
        //
        // The correct diamond topology for wallet funding deposits all A in leg 0,
        // then splits in legs 1+2. Let's do: Leg 0: 2000 A -> B+C via a single
        // maker... No, that won't work either.
        //
        // The real solution: both leg 0 and leg 1 have fromToken=A (inputToken).
        // The SOR pulls initialDepositAmount from wallet on leg 0, and the remaining
        // A needed for leg 1 comes from taker's vault balance.
        // So we deposit some A in vault too.

        // Actually let's do the simplest correct version: all A from wallet on leg 0,
        // then leg 1 is an intermediate that consumes transient B.
        // Diamond: Leg0: 2000 A -> B (hold), Leg1: 500 B -> C (hold), Leg2: 500 B -> D (terminal)
        // But that's not a diamond anymore.
        //
        // True diamond with wallet funding can over-pull into transient on leg0,
        // then spend the residual across later input-token legs. This coverage
        // file keeps the older mixed wallet+vault shape below because it also
        // exercises the vault top-up path; the pure over-pull case is pinned in
        // SeraSOR_OptionB's shared-order multi-fill test.

        // Let's switch to the clean approach: wallet funds 1000, vault funds 1000.
        // This actually tests mixed funding which is even better.
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        // Now taker has 2000 A in wallet and 1000 A in vault.
        // Wait, we already minted 2000 to wallet above. Let's just deposit 1000 to vault.

        t1 = Order({
            user: taker, fromToken: address(A), toToken: address(B),
            fromAmount: 1000 ether, toAmount: 500 ether, initialDepositAmount: 1000 ether,
            feeBps: 0, recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days), uuid: 10
        });
        mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 11, 0, m1);

        // Leg 2: 1000 A -> C. fromToken = A = inputToken, so vault pull is allowed
        Order memory t2 = _oFull(taker, address(A), address(C), 1000 ether, 400 ether, 12, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(A), 400 ether, 1000 ether, 13, 0, m2);

        // Leg 3: sentinel B -> D (terminal)
        Order memory t3 = _oFull(taker, address(B), address(D), 500 ether, 100 ether, 14, 0, taker);
        Order memory mk3 = _oFull(m3, address(D), address(B), 200 ether, 500 ether, 15, 0, m3);

        // Leg 4: sentinel C -> D (terminal)
        Order memory t4 = _oFull(taker, address(C), address(D), 400 ether, 80 ether, 16, 0, taker);
        Order memory mk4 = _oFull(m4, address(D), address(C), 160 ether, 400 ether, 17, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), 1000 ether, mk2, _signOrder(m2PK, mk2, sera), 400 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 200 ether);
        matches[3] = MatchData(t4, bytes(""), type(uint256).max, mk4, _signOrder(m4PK, mk4, sera), 160 ether);

        _exec(matches, taker);

        // Taker's wallet A should be reduced by 1000 (initialDeposit) and vault by 1000 (leg2 pull)
        assertEq(A.balanceOf(taker), 1000 ether, "Taker wallet: 2000 - 1000 wallet deposit = 1000 remaining");
        assertEq(v.balanceOf(address(A), taker), 0, "Taker vault A: 1000 - 1000 vault pull = 0");

        // Taker received D from both branches
        assertGt(D.balanceOf(taker), 0, "Taker received D from wallet-funded diamond");

        // No dust, full solvency
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
        _assertSolvent(address(B));
        _assertSolvent(address(C));
        _assertSolvent(address(D));
    }

    // ====================================================================
    //  Convergent diamond - both terminal legs deliver same output
    //         token to taker (recipient = taker on BOTH final legs).
    //
    //  Topology: A ---> B ---> D   (branch 1, terminal, recipient=taker)
    //            A ---> C ---> D   (branch 2, terminal, recipient=taker)
    //
    //  This tests the case where multiple non-hold legs produce the same
    //  output token. The intent is signed for outputToken=D, and both
    //  legs 2 and 3 should successfully deposit D to the taker.
    //  The totalTakerOutput should be the SUM of both legs.
    // ====================================================================
    function test_Gap3_ConvergentDiamond_BothTerminal() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Leg 0: 1000 A -> B (hold in Sera for leg 2)
        Order memory t0 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 20, 0, address(sera));
        Order memory mk0 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 21, 0, m1);

        // Leg 1: 1000 A -> C (hold in Sera for leg 3)
        Order memory t1 = _oFull(taker, address(A), address(C), 1000 ether, 400 ether, 22, 0, address(sera));
        Order memory mk1 = _oFull(m2, address(C), address(A), 400 ether, 1000 ether, 23, 0, m2);

        // Leg 2: sentinel B -> D (TERMINAL, recipient = taker)
        // Taker gets 200 D for 500 B (1:1 pricing, maker offers exactly what taker needs -> zero spread)
        Order memory t2 = _oFull(taker, address(B), address(D), 500 ether, 200 ether, 24, 0, taker);
        Order memory mk2 = _oFull(m3, address(D), address(B), 200 ether, 500 ether, 25, 0, m3);

        // Leg 3: sentinel C -> D (TERMINAL, recipient = taker)
        // Taker also gets 160 D for 400 C
        Order memory t3 = _oFull(taker, address(C), address(D), 400 ether, 160 ether, 26, 0, taker);
        Order memory mk3 = _oFull(m4, address(D), address(C), 160 ether, 400 ether, 27, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t0, bytes(""), 1000 ether, mk0, _signOrder(m1PK, mk0, sera), 500 ether);
        matches[1] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m2PK, mk1, sera), 400 ether);
        matches[2] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m3PK, mk2, sera), 200 ether);
        matches[3] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m4PK, mk3, sera), 160 ether);

        uint256 takerDBefore = D.balanceOf(taker);

        _exec(matches, taker);

        uint256 takerDReceived = D.balanceOf(taker) - takerDBefore;

        // Both legs have zero spread (executionValue == effectiveAmount on both sides)
        // Leg 2: takerReceives = 200. Leg 3: takerReceives = 160.
        // Total = 360 D
        assertEq(takerDReceived, 360 ether, "Taker received 360 D total (200 + 160 from both branches)");

        // Taker spent all 2000 A
        assertEq(v.balanceOf(address(A), taker), 0, "Taker spent all vault A");

        // No dust, full solvency
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
        _assertSolvent(address(B));
        _assertSolvent(address(C));
        _assertSolvent(address(D));
    }

    // ====================================================================
    //  Convergent diamond with fees + positive slippage on
    //          terminal legs, verifying totalTakerOutput aggregation
    //          against minOutputAmount envelope guard.
    // ====================================================================
    function test_Gap3b_ConvergentDiamond_WithFees_EnvelopeGuard() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        // Leg 0: 1000 A -> B (hold). 5% taker fee.
        // Taker: sell up to 1000 A, want at least 100 B.
        // Maker: sell 500 B, want at least 1 A (very cheap ask).
        Order memory t0 = _oFull(taker, address(A), address(B), 1000 ether, 100 ether, 30, 5_000_000_000_000, address(sera));
        Order memory mk0 = _oFull(m1, address(B), address(A), 500 ether, 1 ether, 31, 0, m1);

        // Leg 1: 1000 A -> C (hold). 3% taker fee.
        // Taker: sell up to 1000 A, want at least 100 C.
        // Maker: sell 400 C, want at least 1 A.
        Order memory t1 = _oFull(taker, address(A), address(C), 1000 ether, 100 ether, 32, 3_000_000_000_000, address(sera));
        Order memory mk1 = _oFull(m2, address(C), address(A), 400 ether, 1 ether, 33, 0, m2);

        // Leg 2: sentinel B -> D (terminal). 2% taker fee.
        // Taker: sell up to 500 B, want at least 10 D.
        // Maker: sell 200 D, want at least 1 B.
        Order memory t2 = _oFull(taker, address(B), address(D), 500 ether, 10 ether, 34, 2_000_000_000_000, taker);
        Order memory mk2 = _oFull(m3, address(D), address(B), 200 ether, 1 ether, 35, 0, m3);

        // Leg 3: sentinel C -> D (terminal). 4% taker fee.
        // Taker: sell up to 400 C, want at least 10 D.
        // Maker: sell 160 D, want at least 1 C.
        Order memory t3 = _oFull(taker, address(C), address(D), 400 ether, 10 ether, 36, 4_000_000_000_000, taker);
        Order memory mk3 = _oFull(m4, address(D), address(C), 160 ether, 1 ether, 37, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t0, bytes(""), 1000 ether, mk0, _signOrder(m1PK, mk0, sera), 500 ether);
        matches[1] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m2PK, mk1, sera), 400 ether);
        matches[2] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m3PK, mk2, sera), 200 ether);
        matches[3] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m4PK, mk3, sera), 160 ether);

        // Sign with envelope guard: minOutputAmount = 10 D (must receive at least 10 total)
        // (Fees + protocol spread consume most of the output)
        uint256 nonce = _execNonce++;
        bytes memory sig = _signIntent(
            takerPK, taker, address(A), address(D), 2000 ether, 10 ether, taker, 0, nonce, uint48(block.timestamp + 1 days), sera
        );
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(taker, address(A), address(D), 2000 ether, 10 ether, taker, 0, nonce, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker should have received > 10 D (the guard passes)
        assertGt(D.balanceOf(taker), 10 ether, "Taker received > 10 D (guard passed)");

        // No dust, full solvency
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
        _assertSolvent(address(B));
        _assertSolvent(address(C));
        _assertSolvent(address(D));
    }

    // ====================================================================
    //  Convergent diamond where minOutput guard REJECTS.
    //          Taker demands 999 D minimum but diamond only delivers ~360.
    // ====================================================================
    function test_Gap3c_ConvergentDiamond_MinOutputReverts() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);
        _mintAndDeposit(m3, address(D), 5000 ether, sera);
        _mintAndDeposit(m4, address(D), 5000 ether, sera);

        Order memory t0 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 40, 0, address(sera));
        Order memory mk0 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 41, 0, m1);

        Order memory t1 = _oFull(taker, address(A), address(C), 1000 ether, 400 ether, 42, 0, address(sera));
        Order memory mk1 = _oFull(m2, address(C), address(A), 400 ether, 1000 ether, 43, 0, m2);

        Order memory t2 = _oFull(taker, address(B), address(D), 500 ether, 200 ether, 44, 0, taker);
        Order memory mk2 = _oFull(m3, address(D), address(B), 200 ether, 500 ether, 45, 0, m3);

        Order memory t3 = _oFull(taker, address(C), address(D), 400 ether, 160 ether, 46, 0, taker);
        Order memory mk3 = _oFull(m4, address(D), address(C), 160 ether, 400 ether, 47, 0, m4);

        MatchData[] memory matches = new MatchData[](4);
        matches[0] = MatchData(t0, bytes(""), 1000 ether, mk0, _signOrder(m1PK, mk0, sera), 500 ether);
        matches[1] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m2PK, mk1, sera), 400 ether);
        matches[2] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m3PK, mk2, sera), 200 ether);
        matches[3] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m4PK, mk3, sera), 160 ether);

        // Sign with impossibly high minOutputAmount
        uint256 nonce = _execNonce++;
        bytes memory sig = _signIntent(
            takerPK, taker, address(A), address(D), 0, 999 ether, taker, 0, nonce, uint48(block.timestamp + 1 days), sera
        );
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InsufficientOutput.selector);
        sor.executeIntent(matches, sig, IntentParams(taker, address(A), address(D), 0, 999 ether, taker, 0, nonce, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ====================================================================
    //  Custom Slippage Shares AND Protocol Fees together
    //
    //  Leg 1: A -> B with 10% Taker/Maker fees AND 100 B spread.
    //  Shares: 25% Maker, 25% Taker, 50% Protocol.
    //  Leg 2: B -> C (Sentinel)
    // ====================================================================
    function test_Gap5_FeesAndPositiveSlippage_Together() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 5000 ether, sera);
        _mintAndDeposit(m2, address(C), 5000 ether, sera);

        // Leg 1: Taker wants 100 B for 1000 A. Maker gives 200 B for 1000 A.
        // Spread = 100 B.
        // Protocol: 50 B. Taker Explicit: 25 B. Maker Implicit: 25 B.
        // executionValue0_adj = 100 + 25 = 125 B.
        // Fee = 10% of 100 B (executionValue0 base) = 10 B.
        // Transient = 125 B - 10 B = 115 B.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 100 ether, 90, 10_000_000_000_000, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 200 ether, 1000 ether, 91, 10_000_000_000_000, m1);

        // Leg 2: Sentinel B -> C. Zero fee.
        // Transient is 115 B. Maker gives 230 C for 115 B.
        Order memory t2 = _oFull(taker, address(B), address(C), 115 ether, 230 ether, 92, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 230 ether, 115 ether, 93, 0, m2);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 200 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 230 ether);

        uint256 nonce = _execNonce++;
        bytes memory sig = _signIntent(takerPK, taker, address(A), address(C), 0, 0, taker, 0, nonce, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(taker, address(A), address(C), 0, 0, taker, 0, nonce, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Transient received 115 B, sent perfectly into Leg 2, yielding 230 C
        assertEq(C.balanceOf(taker), 230 ether, "Taker received 230 C");
        
        // Fee + Spread Protocol captures:
        // Leg 1 Token B (Spread = 50, Fee = 10 -> Total 60)
        assertEq(v.balanceOf(address(B), owner), 60 ether, "Protocol 60 B");
        // Leg 1 Token A (Fee = 10% of 1000 = 100 A)
        assertEq(v.balanceOf(address(A), owner), 100 ether, "Protocol 100 A");
        
        // Maker 1 balance checks: 
        // Authorized 200 B, only 175 B was pulled (115 out + 60 protocol). Implicit 25 B rebate kept!
        // Receiving 900 A (1000 - 100 fee)
        assertEq(v.balanceOf(address(B), m1), 5000 ether - 175 ether, "Maker 1 kept 25 B spread");
        assertEq(A.balanceOf(m1), 900 ether, "Maker 1 got 900 A");
    }
}
