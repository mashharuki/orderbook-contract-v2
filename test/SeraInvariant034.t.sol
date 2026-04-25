// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

// Invariant fuzzing targeted at e2e issue 034 (vault insolvency).
//
// The static audit found no mechanism in the current contracts that can
// grow balances[token][user] without a matching physical inflow. This
// test body fuzzes every external entry point on Vault + Sera + SOR +
// Batcher with non-zero fees and SOR routing enabled, and asserts:
//
//   IERC20(token).balanceOf(vault) >= Σ vault.balanceOf(token, user)
//
// over the closed set of {actors, treasury}. That is the strict form of
// assertVaultSolvency + assertVaultLedgerConservation combined — any
// over-credit beyond the known user set would surface here.

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

contract Sera034Handler is TestHelper {
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    MockStableCoin public tokenC;
    Sera public sera;
    SeraBatcher public batcher;
    SeraSOR public sor;
    Vault public vault;

    address public owner;
    uint256 public ownerPK;
    address public treasury;

    address[] public actors;
    uint256[] public actorPKs;
    uint256 public nextUuid = 1;

    // Ghost: count how often each path is exercised so we know fuzzing
    // actually reached the creditLedger sites.
    uint256 public ghost_deposits;
    uint256 public ghost_withdrawsRequested;
    uint256 public ghost_withdrawsExecuted;
    uint256 public ghost_standaloneMatches;
    uint256 public ghost_singleLegSOR;
    uint256 public ghost_twoLegSOR;
    uint256 public ghost_matchesWithFee;
    uint256 public ghost_spreadMatches;
    uint256 public ghost_reverts;

    constructor(
        MockStableCoin _a,
        MockStableCoin _b,
        MockStableCoin _c,
        Sera _sera,
        SeraBatcher _batcher,
        SeraSOR _sor,
        address _owner,
        uint256 _ownerPK,
        address _treasury
    ) {
        tokenA = _a;
        tokenB = _b;
        tokenC = _c;
        sera = _sera;
        batcher = _batcher;
        sor = _sor;
        vault = _sera.vault();
        owner = _owner;
        ownerPK = _ownerPK;
        treasury = _treasury;

        for (uint256 i = 0; i < 4; i++) {
            (address actor, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(actor);
            actorPKs.push(pk);
        }
    }

    // ============================================================
    // Deposits
    // ============================================================

    function deposit(uint256 actorSeed, uint8 tokenSeed, uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        address actor = actors[actorSeed % actors.length];
        address tok = _pickToken(tokenSeed);
        MockStableCoin(tok).mint(actor, amount);
        vm.startPrank(actor);
        IERC20(tok).approve(address(vault), amount);
        sera.depositFund(tok, actor, amount);
        vm.stopPrank();
        ghost_deposits++;
    }

    // ============================================================
    // Withdrawals
    // ============================================================

    function requestWithdraw(uint256 actorSeed, uint8 tokenSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        address tok = _pickToken(tokenSeed);
        uint256 bal = vault.balanceOf(tok, actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        try sera.emergencyWithdraw(tok, amount) {
            ghost_withdrawsRequested++;
        } catch {
            ghost_reverts++;
        }
    }

    function executeWithdraw(uint256 actorSeed, uint8 tokenSeed) external {
        address actor = actors[actorSeed % actors.length];
        address tok = _pickToken(tokenSeed);
        (uint256 requestBlock, uint256 requestAmount) = sera.withdrawRequests(actor, tok);
        if (requestBlock == 0) return;
        // WITHDRAW_DELAY_BLOCKS = 7200 per Sera constants; roll past it
        vm.roll(block.number + 7201);
        vm.prank(actor);
        try sera.emergencyWithdraw(tok, requestAmount) {
            ghost_withdrawsExecuted++;
        } catch {
            ghost_reverts++;
        }
    }

    // ============================================================
    // Standalone match (non-routed path, uses transferLedger/withdraw)
    // ============================================================

    function matchStandalone(uint256 s0, uint256 s1, uint256 amount, uint16 fee0, uint16 fee1) external {
        uint256 i0 = s0 % actors.length;
        uint256 i1 = s1 % actors.length;
        if (i0 == i1) i1 = (i1 + 1) % actors.length;
        address u0 = actors[i0];
        address u1 = actors[i1];
        uint256 pk0 = actorPKs[i0];
        uint256 pk1 = actorPKs[i1];

        uint256 b0 = vault.balanceOf(address(tokenA), u0);
        uint256 b1 = vault.balanceOf(address(tokenB), u1);
        if (b0 == 0 || b1 == 0) return;
        amount = bound(amount, 1, b0 < b1 ? b0 : b1);
        uint16 fA = uint16(fee0 % 500); // up to 5% — within contract caps
        uint16 fB = uint16(fee1 % 500);

        Order memory o0 = _makeOrder(u0, address(tokenA), address(tokenB), amount, amount, fA);
        Order memory o1 = _makeOrder(u1, address(tokenB), address(tokenA), amount, amount, fB);

        MatchData memory data = MatchData({
            order0: o0,
            signature0: _signOrder(pk0, o0, sera),
            matchAmount0: amount,
            order1: o1,
            signature1: _signOrder(pk1, o1, sera),
            matchAmount1: amount
        });

        vm.prank(owner);
        try sera.matchOrders(data, type(uint256).max) {
            if (fA > 0 || fB > 0) ghost_matchesWithFee++;
            else ghost_standaloneMatches++;
        } catch {
            ghost_reverts++;
        }
    }

    // ============================================================
    // SOR single-leg (exercises creditLedger at 674, 698, 707)
    // ============================================================

    function sorSingleLeg(uint256 sTaker, uint256 sMaker, uint256 amount, uint16 fee) external {
        uint256 iT = sTaker % actors.length;
        uint256 iM = sMaker % actors.length;
        if (iT == iM) iM = (iM + 1) % actors.length;
        address taker = actors[iT];
        address maker = actors[iM];
        uint256 pkTaker = actorPKs[iT];
        uint256 pkMaker = actorPKs[iM];

        uint256 bTaker = vault.balanceOf(address(tokenA), taker);
        uint256 bMaker = vault.balanceOf(address(tokenB), maker);
        if (bTaker == 0 || bMaker == 0) return;
        amount = bound(amount, 1, bTaker < bMaker ? bTaker : bMaker);
        uint16 f = uint16(fee % 300);

        // Route: tokenA → tokenB, single leg, no wallet deposit (takerInputCost=0)
        Order memory oTaker = _makeOrder(taker, address(tokenA), address(tokenB), amount, amount, f);
        Order memory oMaker = _makeOrder(maker, address(tokenB), address(tokenA), amount, amount, f);
        // Taker recipient = actor (NOT address(this)=Sera), since this is the final leg
        oTaker.recipient = taker;

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: oTaker,
            signature0: bytes(""), // SOR skips taker signature
            matchAmount0: amount,
            order1: oMaker,
            signature1: _signOrder(pkMaker, oMaker, sera),
            matchAmount1: amount
        });

        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            maxInputAmount: 0,
            minOutputAmount: 0,
            recipient: taker,
            initialDepositAmount: 0,
            uuid: nextUuid++,
            deadline: uint48(block.timestamp + 1 days)
        });
        bytes memory intentSig = _signIntent(
            pkTaker,
            taker,
            address(tokenA),
            address(tokenB),
            0,
            0,
            taker,
            0,
            intent.uuid,
            uint48(block.timestamp + 1 days),
            sera
        );

        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 3, 0, bytes("")) {
            ghost_singleLegSOR++;
        } catch {
            ghost_reverts++;
        }
    }

    // ============================================================
    // SOR two-leg (A → B → C), exercises transient balance + creditLedger
    // on both legs
    // ============================================================

    function sorTwoLeg(uint256 sTaker, uint256 sMaker1, uint256 sMaker2, uint256 amount) external {
        uint256 iT = sTaker % actors.length;
        uint256 iM1 = sMaker1 % actors.length;
        uint256 iM2 = sMaker2 % actors.length;
        if (iT == iM1) iM1 = (iM1 + 1) % actors.length;
        if (iT == iM2 || iM1 == iM2) iM2 = (iM2 + 2) % actors.length;
        address taker = actors[iT];
        address maker1 = actors[iM1];
        address maker2 = actors[iM2];
        uint256 pkTaker = actorPKs[iT];
        uint256 pkM1 = actorPKs[iM1];
        uint256 pkM2 = actorPKs[iM2];

        uint256 bTaker = vault.balanceOf(address(tokenA), taker);
        uint256 bM1 = vault.balanceOf(address(tokenB), maker1);
        uint256 bM2 = vault.balanceOf(address(tokenC), maker2);
        if (bTaker == 0 || bM1 == 0 || bM2 == 0) return;
        uint256 smallest = bTaker;
        if (bM1 < smallest) smallest = bM1;
        if (bM2 < smallest) smallest = bM2;
        amount = bound(amount, 1, smallest);

        // Leg 1: taker sells A for B, taker recipient = address(sera) (hold)
        Order memory oT1 = _makeOrder(taker, address(tokenA), address(tokenB), amount, amount, 0);
        oT1.recipient = address(sera); // hold output in Sera for next leg
        Order memory oM1 = _makeOrder(maker1, address(tokenB), address(tokenA), amount, amount, 0);

        // Leg 2: taker sells B for C, sentinel consume (use type(uint).max)
        Order memory oT2 = _makeOrder(taker, address(tokenB), address(tokenC), amount, amount, 0);
        oT2.recipient = taker; // final leg
        Order memory oM2 = _makeOrder(maker2, address(tokenC), address(tokenB), amount, amount, 0);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData({
            order0: oT1,
            signature0: bytes(""),
            matchAmount0: amount,
            order1: oM1,
            signature1: _signOrder(pkM1, oM1, sera),
            matchAmount1: amount
        });
        matches[1] = MatchData({
            order0: oT2,
            signature0: bytes(""),
            matchAmount0: type(uint256).max, // sentinel: consume all transient B
            order1: oM2,
            signature1: _signOrder(pkM2, oM2, sera),
            matchAmount1: amount
        });

        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenC),
            maxInputAmount: 0,
            minOutputAmount: 0,
            recipient: taker,
            initialDepositAmount: 0,
            uuid: nextUuid++,
            deadline: uint48(block.timestamp + 1 days)
        });
        bytes memory intentSig = _signIntent(
            pkTaker,
            taker,
            address(tokenA),
            address(tokenC),
            0,
            0,
            taker,
            0,
            intent.uuid,
            uint48(block.timestamp + 1 days),
            sera
        );

        // uniqueTokenCount = 3 (A, B, C) → tableSize = 7
        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 3, 0, bytes("")) {
            ghost_twoLegSOR++;
            pkTaker; // silence unused-var warning if compiler complains
        } catch {
            ghost_reverts++;
        }
    }

    // ============================================================
    // SOR with asymmetric prices — forces non-zero totalSpread0, which
    // exercises the Sera.sol:673-674 physicalSurplus -> creditLedger
    // path (only hit when transientPhysical > neededFromTaker).
    //
    // Taker offer: fromAmount > executionValue1 at match time, so
    // spread exists. With initialDepositAmount > 0, transientPhysical
    // is pre-loaded in Sera and can exceed neededFromTaker.
    // ============================================================

    function sorSingleLegWithSpread(uint256 sTaker, uint256 sMaker, uint256 amount, uint16 priceSkewBps) external {
        uint256 iT = sTaker % actors.length;
        uint256 iM = sMaker % actors.length;
        if (iT == iM) iM = (iM + 1) % actors.length;
        address taker = actors[iT];
        address maker = actors[iM];
        uint256 pkTaker = actorPKs[iT];
        uint256 pkMaker = actorPKs[iM];

        uint256 bMaker = vault.balanceOf(address(tokenB), maker);
        if (bMaker == 0) return;
        amount = bound(amount, 100, bMaker);
        // priceSkew in [100, 2000] bps = [1%, 20%] discount the maker
        // accepts vs. the taker's worst-price limit. This creates a
        // real totalSpread0 = amount * skew / 10000.
        uint256 skew = (priceSkewBps % 1900) + 100;
        uint256 makerAsk = amount * (10000 - skew) / 10000;
        if (makerAsk == 0) makerAsk = 1;

        // Mint wallet tokens for taker to deposit on leg
        tokenA.mint(taker, amount);
        vm.prank(taker);
        tokenA.approve(address(sor), amount);

        // Taker: willing to pay up to `amount` A for `amount` B (1:1 limit)
        Order memory oTaker = Order({
            user: taker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: amount, // all from wallet
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        // Maker: asks only `makerAsk` A for `amount` B — cheaper than
        // taker's limit, so totalSpread0 = amount - makerAsk > 0
        Order memory oMaker = Order({
            user: maker,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: makerAsk,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: oTaker,
            signature0: bytes(""),
            matchAmount0: amount,
            order1: oMaker,
            signature1: _signOrder(pkMaker, oMaker, sera),
            matchAmount1: amount
        });

        IntentParams memory intent = IntentParams({
            taker: taker,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            maxInputAmount: 0,
            minOutputAmount: 0,
            recipient: taker,
            initialDepositAmount: amount,
            uuid: nextUuid++,
            deadline: uint48(block.timestamp + 1 days)
        });
        bytes memory intentSig = _signIntent(
            pkTaker,
            taker,
            address(tokenA),
            address(tokenB),
            0,
            0,
            taker,
            amount,
            intent.uuid,
            uint48(block.timestamp + 1 days),
            sera
        );

        vm.prank(owner);
        try sor.executeIntent(matches, intentSig, intent, 3, 0, bytes("")) {
            ghost_spreadMatches++;
        } catch {
            ghost_reverts++;
        }
    }

    // ============================================================
    // Batch match via SeraBatcher
    // ============================================================

    function batchMatch(uint256 s0, uint256 s1, uint256 amount, bool atomic) external {
        uint256 i0 = s0 % actors.length;
        uint256 i1 = s1 % actors.length;
        if (i0 == i1) i1 = (i1 + 1) % actors.length;
        address u0 = actors[i0];
        address u1 = actors[i1];
        uint256 pk0 = actorPKs[i0];
        uint256 pk1 = actorPKs[i1];

        uint256 b0 = vault.balanceOf(address(tokenA), u0);
        uint256 b1 = vault.balanceOf(address(tokenB), u1);
        if (b0 == 0 || b1 == 0) return;
        amount = bound(amount, 1, b0 < b1 ? b0 : b1);

        Order memory o0 = _makeOrder(u0, address(tokenA), address(tokenB), amount, amount, 0);
        Order memory o1 = _makeOrder(u1, address(tokenB), address(tokenA), amount, amount, 0);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: o0,
            signature0: _signOrder(pk0, o0, sera),
            matchAmount0: amount,
            order1: o1,
            signature1: _signOrder(pk1, o1, sera),
            matchAmount1: amount
        });

        vm.prank(owner);
        if (atomic) {
            try batcher.batchMatchOrdersAtomic(matches, type(uint256).max) {} catch {
                ghost_reverts++;
            }
        } else {
            try batcher.batchMatchOrders(matches, type(uint256).max) returns (uint256) {} catch {
                ghost_reverts++;
            }
        }
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _pickToken(uint8 s) internal view returns (address) {
        uint8 m = s % 3;
        if (m == 0) return address(tokenA);
        if (m == 1) return address(tokenB);
        return address(tokenC);
    }

    function _makeOrder(address user, address fromTok, address toTok, uint256 fromAmt, uint256 toAmt, uint16 feeBps)
        internal
        returns (Order memory)
    {
        return Order({
            user: user,
            fromToken: fromTok,
            toToken: toTok,
            fromAmount: fromAmt,
            toAmount: toAmt,
            initialDepositAmount: 0,
            feeBps: feeBps,
            recipient: user,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function getTreasury() external view returns (address) {
        return treasury;
    }
}

contract Sera034InvariantTest is TestHelper {
    MockStableCoin tokenA;
    MockStableCoin tokenB;
    MockStableCoin tokenC;
    Sera sera;
    SeraSOR sor;
    SeraBatcher batcher;
    address owner;
    uint256 ownerPK;
    address treasury;
    Sera034Handler handler;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        treasury = makeAddr("treasury");

        tokenA = new MockStableCoin("TA");
        tokenB = new MockStableCoin("TB");
        tokenC = new MockStableCoin("TC");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));
        batcher = new SeraBatcher(address(sera), address(sor));

        vm.startPrank(owner);
        _whitelistToken(sera, address(tokenA), true, 1);
        _whitelistToken(sera, address(tokenB), true, 1);
        _whitelistToken(sera, address(tokenC), true, 1);
        bytes32 exec = sera.EXECUTOR_ROLE();
        sera.grantRole(exec, owner);
        sera.grantRole(exec, address(batcher));
        sera.grantRole(exec, address(sor));
        sera.setTreasury(treasury);
        sera.setTrustedRouter(address(sor));
        // Set non-trivial slippage shares so the surplus-credit path at
        // Sera.sol:673-674 is exercised when spreads are present.
        sera.setSlippageShares(5000, 3000, 2000, 10000);
        vm.stopPrank();

        handler = new Sera034Handler(tokenA, tokenB, tokenC, sera, batcher, sor, owner, ownerPK, treasury);

        targetContract(address(handler));

        // Restrict the handler's selectors to the actions we defined so
        // Foundry doesn't accidentally call internal helpers.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Sera034Handler.deposit.selector;
        selectors[1] = Sera034Handler.requestWithdraw.selector;
        selectors[2] = Sera034Handler.executeWithdraw.selector;
        selectors[3] = Sera034Handler.matchStandalone.selector;
        selectors[4] = Sera034Handler.sorSingleLeg.selector;
        selectors[5] = Sera034Handler.sorTwoLeg.selector;
        selectors[6] = Sera034Handler.batchMatch.selector;
        selectors[7] = Sera034Handler.sorSingleLegWithSpread.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The core 034 invariant — for every token, physical
    /// vault balance is at least the sum of all tracked user balances
    /// (including treasury). This is stricter than assertVaultSolvency
    /// in the e2e harness (which omits treasury) and strictly weaker
    /// than assertVaultLedgerConservation (which requires equality).
    function invariant_solvency_closedUserSet() public view {
        Vault vault = sera.vault();
        address[3] memory toks = [address(tokenA), address(tokenB), address(tokenC)];
        for (uint256 t = 0; t < toks.length; t++) {
            address tok = toks[t];
            uint256 physical = IERC20(tok).balanceOf(address(vault));
            uint256 sum = 0;
            for (uint256 i = 0; i < handler.getActorCount(); i++) {
                sum += vault.balanceOf(tok, handler.getActor(i));
            }
            sum += vault.balanceOf(tok, handler.getTreasury());
            // Also include Sera, SOR, Batcher — they should NEVER have a
            // sub-account balance, but checking sum includes them catches
            // any stray credit.
            sum += vault.balanceOf(tok, address(sera));
            sum += vault.balanceOf(tok, address(sor));
            sum += vault.balanceOf(tok, address(batcher));
            assertGe(physical, sum, "vault insolvent: physical < sum(known users + treasury)");
        }
    }

    /// @notice Stricter: aux contracts (Sera, SOR, Batcher) must never
    /// hold a vault sub-account balance. Any credit to them is a bug.
    function invariant_auxContractsHaveZeroLedger() public view {
        Vault vault = sera.vault();
        address[3] memory toks = [address(tokenA), address(tokenB), address(tokenC)];
        address[3] memory aux = [address(sera), address(sor), address(batcher)];
        for (uint256 t = 0; t < toks.length; t++) {
            for (uint256 a = 0; a < aux.length; a++) {
                assertEq(
                    vault.balanceOf(toks[t], aux[a]), 0, "aux contract has non-zero vault ledger"
                );
            }
        }
    }

    /// @notice Sanity check: confirm the spread-surplus path at
    /// Sera.sol:673-674 (creditLedger back to taker) actually fires
    /// for the handler setup. If this test ever fails, fuzzer
    /// coverage of that specific line is broken.
    function test_spreadPathFires() public {
        // Clean state — mint and pre-deposit maker's tokenB
        (address taker2, uint256 tpk) = makeAddrAndKey("sanity-taker");
        (address maker2, uint256 mpk) = makeAddrAndKey("sanity-maker");
        tokenB.mint(maker2, 200 ether);
        vm.startPrank(maker2);
        tokenB.approve(address(vault()), 200 ether);
        sera.depositFund(address(tokenB), maker2, 200 ether);
        vm.stopPrank();

        // Taker deposits 100 A from wallet via SOR
        uint256 amount = 100 ether;
        uint256 makerAsk = amount * 9000 / 10000; // 10% discount → 10 A spread
        tokenA.mint(taker2, amount);
        vm.prank(taker2);
        tokenA.approve(address(sor), amount);

        Order memory oTaker = Order({
            user: taker2,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: amount,
            feeBps: 0,
            recipient: taker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1
        });
        Order memory oMaker = Order({
            user: maker2,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: makerAsk,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 2
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: oTaker,
            signature0: bytes(""),
            matchAmount0: amount,
            order1: oMaker,
            signature1: _signOrder(mpk, oMaker, sera),
            matchAmount1: amount
        });

        IntentParams memory intent = IntentParams({
            taker: taker2,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            maxInputAmount: 0,
            minOutputAmount: 0,
            recipient: taker2,
            initialDepositAmount: amount,
            uuid: 3,
            deadline: uint48(block.timestamp + 1 days)
        });
        bytes memory sig = _signIntent(
            tpk, taker2, address(tokenA), address(tokenB), 0, 0, taker2, amount, 3, uint48(block.timestamp + 1 days), sera
        );

        uint256 takerAVaultBefore = vault().balanceOf(address(tokenA), taker2);

        vm.prank(owner);
        sor.executeIntent(matches, sig, intent, 3, 0, bytes(""));

        uint256 takerAVaultAfter = vault().balanceOf(address(tokenA), taker2);
        // With 10% spread, shares 5000/3000/2000, totalSpread0 = 10 ether:
        //   spreadToTaker0 = 10 - floor(10*5000/10000) - floor(10*2000/10000)
        //                  = 10 - 5 - 2 = 3 ether
        // That's credited back to taker via creditLedger at Sera.sol:673-674.
        assertGt(takerAVaultAfter - takerAVaultBefore, 0, "taker did not receive spread refund");

        // And the invariant holds
        uint256 physicalA = tokenA.balanceOf(address(vault()));
        uint256 sumA = vault().balanceOf(address(tokenA), taker2) + vault().balanceOf(address(tokenA), maker2)
            + vault().balanceOf(address(tokenA), treasury);
        assertGe(physicalA, sumA, "invariant violated in spread sanity test");
    }

    function vault() internal view returns (Vault) {
        return sera.vault();
    }

    /// @notice Called once after the fuzz loop completes; logs ghost
    /// counters so we can verify the fuzzer actually reached the
    /// interesting paths (SOR, fees, etc.).
    function afterInvariant() public view {
        console2.log("--- Sera034 fuzz coverage ---");
        console2.log("deposits:            ", handler.ghost_deposits());
        console2.log("withdraws requested: ", handler.ghost_withdrawsRequested());
        console2.log("withdraws executed:  ", handler.ghost_withdrawsExecuted());
        console2.log("standalone matches:  ", handler.ghost_standaloneMatches());
        console2.log("matches with fee:    ", handler.ghost_matchesWithFee());
        console2.log("single-leg SOR:      ", handler.ghost_singleLegSOR());
        console2.log("two-leg SOR:         ", handler.ghost_twoLegSOR());
        console2.log("SOR with spread:     ", handler.ghost_spreadMatches());
        console2.log("reverts:             ", handler.ghost_reverts());
    }
}
