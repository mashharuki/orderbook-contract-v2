// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_Settlement_Test
 * @dev Tests targeting the settlement optimization:
 *      1. Vault pull optimization: first-leg only pulls neededFromTaker, surplus stays in vault
 *      2. Sentinel surplus safety net: intermediate surplus returned to taker vault
 *      3. Per-leg fee variations: different feeBps on taker/maker per leg
 *      4. Dynamic slippage share changes between routes
 *      5. Exact balance assertions: verify precise debit/credit amounts
 */
contract SeraSOR_Settlement_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;

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

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (m1, m1PK) = makeAddrAndKey("m1");
        (m2, m2PK) = makeAddrAndKey("m2");
        (m3, m3PK) = makeAddrAndKey("m3");

        A = new MockStableCoin("A");
        B = new MockStableCoin("B");
        C = new MockStableCoin("C");
        D = new MockStableCoin("D");

        sera = _deploySera(owner);
        vault = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(A), true, 1);
        _whitelistToken(sera, address(B), true, 1);
        _whitelistToken(sera, address(C), true, 1);
        _whitelistToken(sera, address(D), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        // Default: 25% maker, 25% taker, 50% protocol
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        vm.stopPrank();
    }

    // --------- Helpers ---------


    uint256 private _execNonce = 200;

    function _exec(MatchData[] memory matches) internal {
        _execCore(matches, matches[matches.length - 1].order0.recipient);
    }

    function _execCore(MatchData[] memory matches, address _r) internal {
        uint256 nonce = _execNonce++;
        uint256 _d = matches[0].order0.initialDepositAmount;
        address _in = matches[0].order0.fromToken;
        address _out = matches[matches.length - 1].order0.toToken;
        uint48 _dl = uint48(block.timestamp + 1 days);
        bytes memory sig = _signIntent(takerPK, _in, _out, 0, 0, _r, _d, nonce, _dl, sera);
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(_in, _out, 0, 0, _r, _d, nonce, _dl), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    function _o(address user, address from, address to, uint256 fromAmt, uint256 toAmt, uint256 uuid)
        internal view returns (Order memory)
    {
        return Order({
            user: user, fromToken: from, toToken: to,
            fromAmount: fromAmt, toAmount: toAmt, initialDepositAmount: 0,
            feeBps: 0, recipient: user,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    function _oFull(address user, address from, address to, uint256 fromAmt, uint256 toAmt,
        uint256 uuid, uint48 feeBps, address recipient) internal view returns (Order memory)
    {
        return Order({
            user: user, fromToken: from, toToken: to,
            fromAmount: fromAmt, toAmount: toAmt, initialDepositAmount: 0,
            feeBps: feeBps, recipient: recipient,
            expiration: uint48(block.timestamp + 1 days), uuid: uuid
        });
    }

    function _assertNoDust(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(sera)), 0, "dust in Sera");
    }

    function _assertSolvent(address token) internal view {
        address[4] memory users = [taker, m1, m2, m3];
        uint256 sumLedger;
        for (uint256 i = 0; i < users.length; i++) {
            sumLedger += vault.balanceOf(token, users[i]);
        }
        // Add owner explicitly here
        sumLedger += vault.balanceOf(token, owner);
        // Add treasury only if it's not the owner
        if (sera.treasury() != owner) {
            sumLedger += vault.balanceOf(token, sera.treasury());
        }
        assertGe(IERC20(token).balanceOf(address(vault)), sumLedger, "insolvent");
    }

    // ========================================================================
    // 1. VAULT PULL OPTIMIZATION
    // ========================================================================

    /// @notice First leg with spread: taker vault retains surplus instead of round-tripping.
    /// On-chain math reference:
    ///   executionValue1 = Ceil(matchAmount1 * order1.toAmount / order1.fromAmount)
    ///   protocolFee0 = mulDiv(executionValue1, order1.feeBps, 1e14) — uses ORIGINAL executionValue1
    ///   spreadToTaker0 inflates calc.executionValue1 AFTER protocolFee0 is computed
    ///   makerReceives = calc.executionValue1 - protocolFee0
    ///   neededFromTaker = makerReceives + protocolTake0
    function test_VaultPull_FirstLeg_RetainsSurplus() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        // Taker: 1000 A -> 8 B. Maker: 10 B -> 800 A. No fees.
        // executionValue1 = Ceil(10*800/10) = 800. totalSpread0 = 200.
        // protocolSpread0 = 100. spreadToMaker0 = 50. spreadToTaker0 = 50.
        // calc.executionValue1 = 850. protocolFee0 = 0 (no feeBps).
        // makerReceives = 850. protocolTake0 = 100. neededFromTaker = 950.
        Order memory t1 = _o(taker, address(A), address(B), 1000 ether, 8 ether, 1);
        Order memory mk = _o(m1, address(B), address(A), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 50 ether, "Taker vault retains 50 A");
        assertEq(A.balanceOf(m1), 850 ether, "Maker wallet gets 850 A");
        assertEq(vault.balanceOf(address(A), sera.treasury()), 100 ether, "Treasury gets 100 A");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    /// @notice Zero spread: neededFromTaker == effectiveMatchAmount0
    function test_VaultPull_ZeroSpread_FullDebit() public {
        _mintAndDeposit(taker, address(A), 100 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        Order memory t1 = _o(taker, address(A), address(B), 100 ether, 100 ether, 1);
        Order memory mk = _o(m1, address(B), address(A), 100 ether, 100 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 100 ether, mk, _signOrder(m1PK, mk, sera), 100 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 0, "Taker A fully consumed");
        assertEq(B.balanceOf(taker), 100 ether, "Taker wallet gets 100 B");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    /// @notice First leg with fees + spread: verify exact surplus.
    /// protocolFee0 = mulDiv(executionValue1_ORIGINAL, maker.feeBps, 1e14)
    function test_VaultPull_FirstLeg_WithFees() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        // taker 3% (3e12 bps), maker 1% (1e12 bps)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 8 ether, 1, 3_000_000_000_000, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 10 ether, 800 ether, 2, 1_000_000_000_000, address(0));

        // executionValue1 = 800. protocolFee0 = mulDiv(800, 1e12, 1e14) = 8.
        // totalSpread0 = 200. spreadToTaker0 = 50. calc.executionValue1 = 850.
        // makerReceives = 850 - 8 = 842.
        // protocolTake0 = 8 + 100 = 108. neededFromTaker = 842 + 108 = 950.
        uint256 protocolFee0 = Math.mulDiv(800 ether, 1_000_000_000_000, 100_000_000_000_000); // = 8e18
        uint256 makerReceives = 850 ether - protocolFee0; // = 842e18
        uint256 protocolTake0 = protocolFee0 + 100 ether; // = 108e18
        uint256 neededFromTaker = makerReceives + protocolTake0; // = 950e18
        uint256 expectedRetain = 1000 ether - neededFromTaker; // = 50e18

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), expectedRetain, "Taker retains exact surplus");
        assertEq(vault.balanceOf(address(A), m1), makerReceives, "Maker vault gets exact A");
        assertEq(vault.balanceOf(address(A), sera.treasury()), protocolTake0, "Treasury gets exact A");
        _assertNoDust(address(A));
    }

    // ========================================================================
    // 2. SENTINEL SURPLUS SAFETY NET
    // ========================================================================

    /// @notice Intermediate sentinel with intentional spread -> surplus to vault
    function test_Sentinel_IntermediateSpread_SurplusToVault() public {
        _mintAndDeposit(taker, address(A), 100 ether, sera);
        _mintAndDeposit(m1, address(B), 200 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);

        // Leg 1: A->B. Zero spread. 100A->50B.
        Order memory t1 = _o(taker, address(A), address(B), 100 ether, 50 ether, 1);
        t1.recipient = address(sera);
        Order memory mk1 = _o(m1, address(B), address(A), 50 ether, 100 ether, 2);

        // Leg 2: B->C. Sentinel resolves to 50B. Maker: 100C->20B.
        // executionValue1 = 20. spread = 50-20 = 30. Surplus returned to vault.
        Order memory t2 = _o(taker, address(B), address(C), 100 ether, 5 ether, 3);
        Order memory mk2 = _o(m2, address(C), address(B), 100 ether, 20 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 100 ether, mk1, _signOrder(m1PK, mk1, sera), 50 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 100 ether);
        _exec(matches);

        assertGt(vault.balanceOf(address(B), taker), 0, "Taker B surplus in vault");
        assertGt(C.balanceOf(taker), 0, "Taker received C");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
    }

    /// @notice executor-calibrated: zero intermediate spread
    function test_Sentinel_MECalibrated_ZeroSurplus() public {
        _mintAndDeposit(taker, address(A), 100 ether, sera);
        _mintAndDeposit(m1, address(B), 200 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);

        // Leg 1: A->B. 100A->50B. Exact pricing.
        Order memory t1 = _o(taker, address(A), address(B), 100 ether, 50 ether, 1);
        t1.recipient = address(sera);
        Order memory mk1 = _o(m1, address(B), address(A), 50 ether, 100 ether, 2);
        // takerReceives = 50B.

        // Leg 2: B->C. Sentinel = 50B. Maker: 200C->50B. executionValue1=50. Spread=0.
        Order memory t2 = _o(taker, address(B), address(C), 100 ether, 10 ether, 3);
        Order memory mk2 = _o(m2, address(C), address(B), 200 ether, 50 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 100 ether, mk1, _signOrder(m1PK, mk1, sera), 50 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 200 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(B), taker), 0, "No B surplus");
        assertEq(vault.balanceOf(address(A), taker), 0, "Taker A consumed");
        assertGt(C.balanceOf(taker), 0, "Taker got C");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
    }

    // ========================================================================
    // 3. PER-LEG FEE VARIATIONS
    // ========================================================================

    /// @notice Two legs, different fees: 5% taker on leg1, 10% maker on leg2. Zero spread.
    function test_PerLegFees_DifferentFeesPerLeg() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 500 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);

        // Leg 1: 1000A->500B. Exact pricing. 5% taker, 0% maker.
        // executionValue0 = Ceil(1000*500/1000) = 500B. protocolFee1 = mulDiv(500, 5e12, 1e14) = 25.
        // takerReceives = 500 - 25 = 475B.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, 5_000_000_000_000, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 0, address(0));

        // Leg 2: sentinel B->C. 0% taker, 10% maker. Sentinel = 475B.
        // ME calibrates: Maker 475C->475B. executionValue1 = 475. Spread = 0.
        // protocolFee0 = mulDiv(475, 1e13, 1e14) = 47.5e18.
        // makerReceives = 475 - 47.5 = 427.5. protocolTake0 = 47.5.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 100 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 475 ether, 475 ether, 4, 10_000_000_000_000, address(0));

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 475 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 0, "Taker A consumed");
        assertGt(C.balanceOf(taker), 0, "Taker got C");
        assertEq(vault.balanceOf(address(A), m1), 1000 ether, "Maker1 vault A");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertSolvent(address(A));
        // B leaves vault to maker2 via creditLedger, and C leaves vault to taker wallet
        // so only check A solvency; B/C solvency is covered by no-dust + passing execution
    }

    /// @notice Three legs: 0% -> 0% -> 5% taker fee. Zero spread. Exact output assertion.
    function test_PerLegFees_EscalatingTakerFees() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 500 ether, sera);
        _mintAndDeposit(m2, address(C), 250 ether, sera);
        _mintAndDeposit(m3, address(D), 500 ether, sera);

        // Leg 1: A->B. 0% fee. 1000A->500B. Exact. takerReceives = 500B.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 0, address(0));

        // Leg 2: B->C. 0% fee. sentinel=500B. 500B->250C. Exact. takerReceives = 250C.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 250 ether, 3, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(B), 250 ether, 500 ether, 4, 0, address(0));

        // Leg 3: C->D. 5% taker fee. sentinel=250C. 250C->125D. Exact.
        // executionValue0 = Ceil(250*125/250) = 125. protocolFee1 = mulDiv(125, 5e12, 1e14) = 6.25e18.
        // takerReceives = 125 - 6.25 = 118.75e18.
        Order memory t3 = _oFull(taker, address(C), address(D), 250 ether, 125 ether, 5, 5_000_000_000_000, taker);
        Order memory mk3 = _oFull(m3, address(D), address(C), 125 ether, 250 ether, 6, 0, address(0));

        uint256 fee = Math.mulDiv(125 ether, 5_000_000_000_000, 100_000_000_000_000);
        uint256 expectedD = 125 ether - fee;

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 250 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 125 ether);
        _exec(matches);

        assertEq(D.balanceOf(taker), expectedD, "Taker D = 125 - 5% fee");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
    }

    /// @notice Per-leg 10% maker fee on second leg only
    function test_PerLegFees_HighMakerFee_SecondLeg() public {
        _mintAndDeposit(taker, address(A), 100 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);
        _mintAndDeposit(m2, address(C), 100 ether, sera);

        // Leg 1: A->B. 0% fees. 100A->50B. Exact. takerReceives = 50B.
        Order memory t1 = _oFull(taker, address(A), address(B), 100 ether, 50 ether, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 50 ether, 100 ether, 2, 0, address(0));

        // Leg 2: B->C. 0% taker, 10% maker. sentinel=50B. 100C->50B.
        // protocolFee0 = mulDiv(50, 1e13, 1e14) = 5. makerReceives = 50-5 = 45.
        Order memory t2 = _oFull(taker, address(B), address(C), 50 ether, 50 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 100 ether, 50 ether, 4, 10_000_000_000_000, address(0));

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 100 ether, mk1, _signOrder(m1PK, mk1, sera), 50 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 100 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(B), m2), 45 ether, "Maker2 gets 45B after 10% fee");
        assertEq(vault.balanceOf(address(B), sera.treasury()), 5 ether, "Treasury gets 5B");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
    }

    // ========================================================================
    // 4. DYNAMIC SLIPPAGE SHARES
    // ========================================================================

    /// @notice Two routes: 25/25/50 then 0/0/100 shares. Different surplus retained.
    function test_DynamicShares_ChangeBetweenRoutes() public {
        _mintAndDeposit(taker, address(A), 2000 ether, sera);
        _mintAndDeposit(m1, address(B), 200 ether, sera);
        _mintAndDeposit(m2, address(B), 200 ether, sera);

        // Route 1: spread=200. spreadToTaker0=50. neededFromTaker=950.
        {
            Order memory t1 = _o(taker, address(A), address(B), 1000 ether, 10 ether, 1);
            Order memory mk1 = _o(m1, address(B), address(A), 100 ether, 800 ether, 2);
            MatchData[] memory matches = new MatchData[](1);
            matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 100 ether);
            _exec(matches);
        }
        assertEq(vault.balanceOf(address(A), taker), 1050 ether, "After R1: 1050 A");

        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000);

        // Route 2: spread=200. All to protocol. neededFromTaker = 800+200 = 1000.
        {
            Order memory t2 = _o(taker, address(A), address(B), 1000 ether, 10 ether, 3);
            Order memory mk2 = _o(m2, address(B), address(A), 100 ether, 800 ether, 4);
            MatchData[] memory matches = new MatchData[](1);
            matches[0] = MatchData(t2, bytes(""), 1000 ether, mk2, _signOrder(m2PK, mk2, sera), 100 ether);
            _exec(matches);
        }
        assertEq(vault.balanceOf(address(A), taker), 50 ether, "After R2: 50 A");
    }

    /// @notice 100% maker shares -> maker implicit rebate, taker retains surplus in vault
    function test_Shares_AllMaker() public {
        vm.prank(owner);
        sera.setSlippageShares(10000, 0, 0, 10000);

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        // spreadToMaker0 = 200. spreadToTaker0 = 0. calc.executionValue1 = 800.
        // makerReceives = 800. neededFromTaker = 800. Taker retains 200.
        Order memory t1 = _o(taker, address(A), address(B), 1000 ether, 8 ether, 1);
        Order memory mk = _o(m1, address(B), address(A), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 200 ether, "Taker retains 200 A");
        assertEq(A.balanceOf(m1), 800 ether, "Maker wallet gets 800 A");
    }

    /// @notice 100% taker shares -> spreadToTaker0 inflates calc.executionValue1
    function test_Shares_AllTaker() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 10000, 0, 10000);

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        // spreadToTaker0 = 200. calc.executionValue1 = 1000. makerReceives = 1000.
        // neededFromTaker = 1000. Taker retains 0.
        Order memory t1 = _o(taker, address(A), address(B), 1000 ether, 8 ether, 1);
        Order memory mk = _o(m1, address(B), address(A), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 0, "Taker retains 0 A");
        assertEq(A.balanceOf(m1), 1000 ether, "Maker gets full 1000 A");
    }

    // ========================================================================
    // 5. COMBINED SCENARIOS
    // ========================================================================

    /// @notice Vault pull + sentinel surplus in same route
    function test_Combined_VaultPullAndSentinelSurplus() public {
        _mintAndDeposit(taker, address(A), 500 ether, sera);
        _mintAndDeposit(m1, address(B), 200 ether, sera);
        _mintAndDeposit(m2, address(C), 200 ether, sera);

        // Leg 1: A->B with spread. 500A->10B. Maker: 50B->200A.
        // executionValue1 = 200. spread0 = 300. spreadToTaker0=75. neededFromTaker = 275+150 = 425.
        // Leg1 output: executionValue0 = Ceil(500*10/500) = 10. totalSpread1 = 50-10 = 40.
        // spreadToMaker1 = 10. calc.executionValue0 = 20. takerReceives = 20B -> sera.
        Order memory t1 = _o(taker, address(A), address(B), 500 ether, 10 ether, 1);
        t1.recipient = address(sera);
        Order memory mk1 = _o(m1, address(B), address(A), 50 ether, 200 ether, 2);

        // Leg 2: B->C. Sentinel = 20B. Maker: 100C->10B. executionValue1 = 10. spread = 10B.
        Order memory t2 = _o(taker, address(B), address(C), 100 ether, 5 ether, 3);
        Order memory mk2 = _o(m2, address(C), address(B), 100 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 500 ether, mk1, _signOrder(m1PK, mk1, sera), 50 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 100 ether);
        _exec(matches);

        assertGt(vault.balanceOf(address(A), taker), 0, "Taker A retained");
        assertGt(vault.balanceOf(address(B), taker), 0, "Taker B surplus returned");
        assertGt(C.balanceOf(taker), 0, "Taker got C");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
    }

    /// @notice Three-leg executor-calibrated, per-leg fees, exact output assertion.
    function test_Combined_ThreeLeg_MECalibrated_PerLegFees() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 500 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);
        _mintAndDeposit(m3, address(D), 500 ether, sera);

        // All zero spread (executor-calibrated). Per-leg fees.

        // Leg 1: A->B. 2% taker. 1000A->500B. Exact pricing (1:1 scaled).
        // executionValue0 = Ceil(1000*500/1000) = 500B. protocolFee1 = mulDiv(500, 2e12, 1e14) = 10.
        // takerReceives = 490B.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, 2_000_000_000_000, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 0, address(0));

        // Leg 2: B->C. 0% fees. sentinel=490B. 1:1 pricing to consume exactly 490B.
        // Maker: 490C->490B. executionValue1 = 490. Spread=0. takerReceives = 490C.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 500 ether, 3, 0, address(sera));
        Order memory mk2 = _oFull(m2, address(C), address(B), 490 ether, 490 ether, 4, 0, address(0));

        // Leg 3: C->D. 5% taker, 0% maker. sentinel=490C. 1:2 pricing.
        // Maker: 245D->490C. executionValue0 = Ceil(490*245/490) = 245D.
        // protocolFee1 = mulDiv(245, 5e12, 1e14) = 12.25e18.
        // takerReceives = 245 - 12.25 = 232.75e18.
        Order memory t3 = _oFull(taker, address(C), address(D), 500 ether, 250 ether, 5, 5_000_000_000_000, taker);
        Order memory mk3 = _oFull(m3, address(D), address(C), 245 ether, 490 ether, 6, 0, address(0));

        uint256 fee3 = Math.mulDiv(245 ether, 5_000_000_000_000, 100_000_000_000_000);
        uint256 expectedD = 245 ether - fee3;

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 490 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, mk3, _signOrder(m3PK, mk3, sera), 245 ether);
        _exec(matches);

        assertEq(D.balanceOf(taker), expectedD, "Taker D exact");
        assertEq(vault.balanceOf(address(B), taker), 0, "No B surplus");
        assertEq(vault.balanceOf(address(C), taker), 0, "No C surplus");
        assertEq(vault.balanceOf(address(A), taker), 0, "Taker A consumed");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        _assertNoDust(address(D));
        _assertSolvent(address(A));
    }

    /// @notice Audit verification: Mixed transient (wallet) and vault balances mathematically
    /// refund physical surplus back to user's vault.
    function test_Audit_Fixed_MixedSettlementRefundsPhysicalSurplus() public {
        // Taker has 40 A in their wallet, and 60 A in their vault. (Total 100 A provided)
        A.mint(taker, 40 ether);
        _mintAndDeposit(taker, address(A), 60 ether, sera);
        
        vm.prank(taker);
        A.approve(address(sor), type(uint256).max);
        
        // Maker is selling 80 B for 80 A. So neededFromTaker = 80 A.
        _mintAndDeposit(m1, address(B), 80 ether, sera);
        Order memory mk1 = _o(m1, address(B), address(A), 80 ether, 80 ether, 1);
        
        // Taker orders to spend 100 A for 80 B. Spread = +20 A.
        Order memory t1 = _o(taker, address(A), address(B), 100 ether, 80 ether, 2);
        t1.initialDepositAmount = 40 ether; // Signals executeIntent to pull 40 physically from wallet
        t1.recipient = taker;
        
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 100 ether, mk1, _signOrder(m1PK, mk1, sera), 80 ether);
        
        uint256 nonce = _execNonce++;
        bytes memory sig = _signIntent(takerPK, address(A), address(B), 100 ether, 80 ether, taker, 40 ether, nonce, uint48(block.timestamp + 1 days), sera);
        
        // Execute the SOR
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(address(A), address(B), 100 ether, 80 ether, taker, 40 ether, nonce, uint48(block.timestamp + 1 days)), uint8(3), 0, bytes(""));
        
        // Verify Fix:
        assertEq(A.balanceOf(taker), 0, "Wallet completely pulled");
        
        // --- MATH BREAKDOWN ---
        // Taker Cost = 100 A. Maker expects = 80 A. Spread = +20 A.
        // setUp() configured SlippageShares: Protocol=50%, Taker=25%, Maker=25%.
        // Spread distribution: Protocol=10, Taker=5, Maker=5.
        // neededFromTaker = MakerBase(80) + MakerSpreadBonus(5) + ProtocolSpreadTake(10) = 95 A.
        // transientPhysical = 40. 
        // Actual Vault Pull = neededFromTaker(95) - transientPhysical(40) = 55 A.
        // Taker Vault Remaining = Initial(60) - Pulled(55) = 5 A. 
        // (This exactly equates to the 5 A Taker Spread Refund!)
        assertEq(vault.balanceOf(address(A), taker), 5 ether, "Vault natively holds exact taker spread refund (5 A)");
        
        // Maker receives Base(80) + Bonus(5) in their wallet because _o sets recipient = m1
        assertEq(A.balanceOf(m1), 85 ether, "Maker paid accurately with spread bonus to wallet");
        
        // Protocol treasury receives 10 A in the vault
        assertEq(vault.balanceOf(address(A), sera.treasury()), 10 ether, "Treasury captured protocol spread in vault");
        
        // Sera should not hold any ghost tokens.
        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertSolvent(address(A));
        _assertSolvent(address(B));
    }
}
