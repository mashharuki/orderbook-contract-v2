// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_Extreme_Test
 * @dev Exhaustive extreme scenario tests for financial correctness:
 *      - dust-fix verification (single-leg, multi-leg, all slippage configs)
 *      - Token conservation invariants under all spread/fee combos
 *      - Rounding edge cases at wei level across multi-leg routes
 *      - Asymmetric spreads, maximum fees, and partial fill interactions
 *      - Solvency proofs after complex routes
 */
contract SeraSOR_Extreme_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public usdc;
    MockStableCoin public eth;
    MockStableCoin public btc;
    MockStableCoin public dai;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;
    address public maker3;
    uint256 public maker3PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");
        (maker3, maker3PK) = makeAddrAndKey("maker3");

        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");
        btc = new MockStableCoin("BTC");
        dai = new MockStableCoin("DAI");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        _whitelistToken(sera, address(btc), true, 1);
        _whitelistToken(sera, address(dai), true, 1);
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

    /// @dev Check that Sera holds zero physical balance of a token after settlement
    function _assertNoSeraDust(address token, string memory label) internal view {
        assertEq(IERC20(token).balanceOf(address(sera)), 0, string.concat("No dust in Sera: ", label));
    }

    /// @dev Check vault solvency: actual >= ledger sum for all tracked users
    function _assertVaultSolvent(address token, address[] memory users, string memory label) internal view {
        Vault v = sera.vault();
        uint256 totalLedger = 0;
        for (uint256 i = 0; i < users.length; i++) {
            totalLedger += v.balanceOf(token, users[i]);
        }
        assertGe(IERC20(token).balanceOf(address(v)), totalLedger, string.concat("Vault solvent: ", label));
    }

    // ========================================================================
    // 1. DUST-FIX VERIFICATION — SINGLE LEG WITH SPREAD
    // ========================================================================

    /// @notice Verify Dust-fix: no dust when 25% maker / 25% taker / 50% protocol
    function test_NoDust_SingleLeg_MixedShares() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Spread: taker 1000→8, maker 10→800 → 200 USDC spread
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 101, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 101, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Dust-fix: no tokens should remain in Sera
        _assertNoSeraDust(address(usdc), "USDC after mixed-share spread");
        _assertNoSeraDust(address(eth), "ETH after mixed-share spread");

        // Spread distribution explicit checks
        Vault v = sera.vault();
        assertEq(v.balanceOf(address(usdc), taker), 50 ether, "Taker received 50 USDC rebate (25%)");
        assertEq(usdc.balanceOf(maker1), 850 ether, "Maker received 800 execution + 50 spread (25%)");
        assertEq(v.balanceOf(address(usdc), owner), 100 ether, "Treasury captured 100 USDC spread (50%)");
    }

    /// @notice Verify no dust with 100% maker share (all spread → maker rebate)
    function test_NoDust_SingleLeg_AllMakerShare() public {
        vm.prank(owner);
        sera.setSlippageShares(10000, 0, 0, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 102, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 102, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC with 100% maker share");
        // 100% maker (TAKER bonus) share
        assertEq(sera.vault().balanceOf(address(usdc), taker), 200 ether, "Taker got full 200 USDC rebate");
        assertEq(usdc.balanceOf(maker1), 800 ether, "Maker got NO spread, just execution value");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 0, "Treasury captured 0 spread");
    }

    /// @notice Verify no dust with zero spread (exact price match)
    function test_NoDust_ZeroSpread() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // No spread: taker 1000→10, maker 10→1000 (exact match)
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 103, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 103, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC zero-spread");
        _assertNoSeraDust(address(eth), "ETH zero-spread");
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Taker paid exact amount (no rebate)");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker got exact execution value");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 0, "Treasury captured 0 spread");
        assertEq(sera.vault().balanceOf(address(eth), owner), 0, "Treasury captured 0 ETH spread");
    }

    // ========================================================================
    // 2. MULTI-LEG DUST ACCUMULATION (was the main dust risk)
    // ========================================================================

    /// @notice 3-leg route: USDC→ETH→BTC→DAI with spread on every leg
    function test_NoDust_ThreeLegRoute_SpreadEveryLeg() public {
        vm.prank(owner);
        sera.setSlippageShares(3000, 3000, 4000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);
        _mintAndDeposit(maker2, address(btc), 5 ether, sera);
        _mintAndDeposit(maker3, address(dai), 2000 ether, sera);

        // Leg 1: USDC→ETH with spread (taker:1000→8, maker:10→800)
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t1.recipient = address(sera); // hold for next leg
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        // Leg 2: ETH→BTC with spread
        // From Leg 1, taker receives ~8 ETH (executionValue0 minus spread adjustments)
        // taker: 10→1 BTC, maker: 2→16 ETH. matchAmount1=2 BTC
        // executionValue0 = Ceil(effectiveETH * 1/10). executionValue1 = Ceil(2 * 16/2) = 16 ETH
        // But effectiveETH ~ 8 which is < 16 → InvalidCostAmount!
        // Fix: maker2 offers cheaper rate: 2 BTC for 5 ETH, fill 2 BTC
        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        t2.recipient = address(sera);
        Order memory m2 = _makeOrder(maker2, address(btc), address(eth), 2 ether, 5 ether, 4);

        // Leg 3: BTC→DAI. taker: 2→100 DAI, maker: 200→1 BTC, fill 200 DAI
        // executionValue0 = Ceil(effectiveBTC * 100/2). executionValue1 = Ceil(200 * 1/200) = 1 BTC
        // effectiveBTC ~ 2, so executionValue0 = Ceil(2 * 100/2) = 100 DAI.
        // matchAmount1(200) >= executionValue0(100) ✓. effectiveBTC(~2) >= executionValue1(1) ✓
        Order memory t3 = _makeOrder(taker, address(btc), address(dai), 2 ether, 100 ether, 5);
        Order memory m3 = _makeOrder(maker3, address(dai), address(btc), 200 ether, 1 ether, 6);

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, m1, _signOrder(maker1PK, m1, sera), 10 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), 2 ether);
        matches[2] = MatchData(t3, bytes(""), type(uint256).max, m3, _signOrder(maker3PK, m3, sera), 200 ether);

        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 104, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 104, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Dust-fix: NO dust should remain in Sera for ANY token
        _assertNoSeraDust(address(usdc), "USDC after 3-leg");
        _assertNoSeraDust(address(eth), "ETH after 3-leg");
        _assertNoSeraDust(address(btc), "BTC after 3-leg");
        _assertNoSeraDust(address(dai), "DAI after 3-leg");

        // Vault solvency for all tokens
        address[] memory users = new address[](5);
        users[0] = taker; users[1] = maker1; users[2] = maker2; users[3] = maker3; users[4] = owner;
        _assertVaultSolvent(address(usdc), users, "USDC");
        _assertVaultSolvent(address(eth), users, "ETH");
        _assertVaultSolvent(address(btc), users, "BTC");
        _assertVaultSolvent(address(dai), users, "DAI");

        Vault v = sera.vault();
        assertGt(v.balanceOf(address(usdc), owner), 0, "Treasury captured USDC spread (40%)");
        assertGt(v.balanceOf(address(eth), owner), 0, "Treasury captured ETH spread (40%)");
        assertGt(v.balanceOf(address(btc), owner), 0, "Treasury captured BTC spread (40%)");
    }

    // ========================================================================
    // 3. COMBINED FEES + SPREAD + SENTINEL + DUST CHECK
    // ========================================================================

    /// @notice Fees (3% taker, 1% maker) + spread + sentinel 2-leg route
    function test_NoDust_FeesAndSpreadWithSentinel() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 5 ether, sera);

        // Leg 1: USDC→ETH with 3% taker fee, spread
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t1.feeBps = 3_000_000_000_000; // 3%
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);
        m1.feeBps = 1_000_000_000_000; // 1%

        // Leg 2: ETH→BTC with sentinel, 1% taker, 0.5% maker
        // Taker receives ~7.76 ETH from Leg 1 (after fee+spread distribution)
        // taker: 10→1 BTC, maker: 1 BTC→5 ETH
        // executionValue0 = Ceil(effectiveETH * 1/10) = ~1 BTC
        // executionValue1 = Ceil(1 * 5/1) = 5 ETH. effectiveETH(~7.76) >= 5 ✓
        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        t2.feeBps = 1_000_000_000_000;
        Order memory m2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 5 ether, 4);
        m2.feeBps = 500_000_000_000;

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, m1, _signOrder(maker1PK, m1, sera), 10 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), 1 ether);

        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 105, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 105, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC fees+spread+sentinel");
        _assertNoSeraDust(address(eth), "ETH fees+spread+sentinel");
        _assertNoSeraDust(address(btc), "BTC fees+spread+sentinel");

        // Treasury should have captured fees + protocol spread
        Vault v = sera.vault();
        assertGt(v.balanceOf(address(usdc), owner), 0, "Treasury captured USDC fees/spread");
        assertGt(v.balanceOf(address(eth), owner), 0, "Treasury captured ETH fees/spread");
    }

    // ========================================================================
    // 4. WEI-LEVEL ROUNDING ACROSS MULTI-LEG
    // ========================================================================

    /// @notice Tiny amounts (3, 7, 11 wei) with uneven ratios — tests rounding
    function test_NoDust_WeiLevelRounding_TwoLeg() public {
        vm.prank(owner);
        sera.setSlippageShares(3333, 3333, 3334, 10000); // Near-equal split

        _mintAndDeposit(taker, address(usdc), 100, sera);
        _mintAndDeposit(maker1, address(eth), 50, sera);
        _mintAndDeposit(maker2, address(btc), 20, sera);

        // Leg 1: 7 USDC → ?? ETH. Taker: 100→3, Maker: 50→10
        // match: 7 USDC, 7 ETH
        // executionValue0 = Ceil(7 * 3/100) = 1 ETH
        // executionValue1 = Ceil(7 * 10/50) = 2 USDC
        // matchAmount0(7) >= executionValue1(2) ✓, matchAmount1(7) >= executionValue0(1) ✓
        // Spread: USDC = 7 - 2 = 5, ETH = 7 - 1 = 6
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 100, 3, 1);
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 50, 10, 2);

        // Leg 2: ETH → BTC. Taker: 10→1, Maker: 1→1
        // sentinel resolves to ~2 ETH from leg 1
        // executionValue0 = Ceil(effectiveETH * 1/10) = 1 BTC
        // executionValue1 = Ceil(1 * 1/1) = 1 ETH. effectiveETH(~2) >= 1 ✓
        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 10, 1, 3);
        Order memory m2 = _makeOrder(maker2, address(btc), address(eth), 1, 1, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 7, m1, _signOrder(maker1PK, m1, sera), 7);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), 1);

        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 106, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 106, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Even at wei level with rounding, no dust
        _assertNoSeraDust(address(usdc), "USDC wei-level");
        _assertNoSeraDust(address(eth), "ETH wei-level");
        _assertNoSeraDust(address(btc), "BTC wei-level");

        // Vault solvency at wei level
        address[] memory users = new address[](4);
        users[0] = taker; users[1] = maker1; users[2] = maker2; users[3] = owner;
        _assertVaultSolvent(address(usdc), users, "USDC wei");
        _assertVaultSolvent(address(eth), users, "ETH wei");
        _assertVaultSolvent(address(btc), users, "BTC wei");
    }

    // ========================================================================
    // 5. WALLET-FUNDED ROUTE WITH SPREAD + DUST CHECK
    // ========================================================================

    /// @notice initialDepositAmount > 0 (wallet-funded) + spread
    function test_NoDust_WalletFunded_WithSpread() public {
        vm.prank(owner);
        sera.setSlippageShares(2000, 3000, 5000, 10000);

        // Taker has USDC in wallet (not vault)
        usdc.mint(taker, 1000 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t.initialDepositAmount = 1000 ether;
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, 107, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, 107, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC wallet-funded with spread");
        _assertNoSeraDust(address(eth), "ETH wallet-funded with spread");

        // Spread distribution logic
        assertEq(sera.vault().balanceOf(address(usdc), taker), 40 ether, "Taker vault received 40 USDC rebate (20%)");
        assertEq(usdc.balanceOf(maker1), 860 ether, "Maker received 800 execution + 60 spread (30%)");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 100 ether, "Treasury captured 100 USDC spread (50%)");
    }

    // ========================================================================
    // 6. MAXIMUM SPREAD — EXTREME RATE ASYMMETRY
    // ========================================================================

    /// @notice Maximum spread: taker offers 1000→1 (generous), maker offers 100→100000 (also generous)
    function test_NoDust_MaximumSpread() public {
        vm.prank(owner);
        sera.setSlippageShares(5000, 5000, 0, 10000); // No protocol take

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 100 ether, sera);

        // Taker: 1000 USDC for just 1 ETH (very generous)
        // Maker: 100 ETH for just 100000 USDC (also generous)
        // matchAmount0=1000, matchAmount1=100
        // executionValue0 = Ceil(1000 * 1/1000) = 1 ETH
        // executionValue1 = Ceil(100 * 100000/100) = 100000 USDC — but matchAmount0=1000 < 100000 → InvalidCostAmount
        // Need to fix amounts. Let me make it so maker is generous:
        // Maker offers 100 ETH for 500 USDC. matchAmount1=10
        // executionValue1 = Ceil(10 * 500/100) = 50 USDC
        // executionValue0 = Ceil(1000 * 1/1000) = 1 ETH
        // Check: matchAmount0(1000) >= executionValue1(50) ✓, matchAmount1(10) >= executionValue0(1) ✓
        // Spread: USDC = 1000 - 50 = 950, ETH = 10 - 1 = 9
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 1 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 100 ether, 500 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 108, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 108, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC max-spread");
        _assertNoSeraDust(address(eth), "ETH max-spread");

        // Spread distribution explicit checks
        assertEq(sera.vault().balanceOf(address(usdc), taker), 475 ether, "Taker received 475 USDC rebate (50%)");
        assertEq(usdc.balanceOf(maker1), 525 ether, "Maker received 50 execution + 475 spread (50%)");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 0, "Treasury captured 0 spread");
    }

    // ========================================================================
    // 7. ONE-SIDED SPREAD
    // ========================================================================

    /// @notice Token 0 spread but zero Token 1 spread
    function test_NoDust_OneSidedSpread() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Taker: 1000 USDC → 10 ETH (exact rate)
        // Maker: 10 ETH → 500 USDC (gives more ETH per USDC — spread only on USDC side)
        // executionValue0 = Ceil(1000 * 10/1000) = 10 ETH
        // executionValue1 = Ceil(10 * 500/10) = 500 USDC
        // Spread: USDC = 1000 - 500 = 500, ETH = 10 - 10 = 0
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 500 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 109, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 109, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC one-sided spread");
        _assertNoSeraDust(address(eth), "ETH one-sided spread");

        // One-sided spread distribution
        assertEq(sera.vault().balanceOf(address(usdc), taker), 125 ether, "Taker rebate from one-sided spread (25%)");
        assertEq(usdc.balanceOf(maker1), 625 ether, "Maker received 500 execution + 125 spread (25%)");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 250 ether, "Treasury captured 250 USDC spread (50%)");
    }

    // ========================================================================
    // 8. TOKEN CONSERVATION INVARIANT — COMPLEX ROUTE WITH FEES + ALL SHARES
    // ========================================================================

    /// @notice Verify total token conservation: sum of all balances before == after
    function test_TokenConservation_FullRoute() public {
        vm.prank(owner);
        sera.setSlippageShares(2000, 3000, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);
        _mintAndDeposit(maker2, address(btc), 5 ether, sera);

        // Record total supply before
        uint256 totalUsdcBefore = usdc.totalSupply();
        uint256 totalEthBefore = eth.totalSupply();
        uint256 totalBtcBefore = btc.totalSupply();

        // 2-leg: USDC→ETH→BTC with fees
        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 15 ether, 1);
        t1.feeBps = 2_000_000_000_000; // 2%
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 1500 ether, 2);
        m1.feeBps = 1_000_000_000_000;

        // From Leg 1: taker gets ~15 ETH (before fees/spread adjustments → maybe ~14 ETH)
        // Leg 2: taker: 20→1 BTC, maker: 3→10 ETH
        // executionValue0 = Ceil(effectiveETH * 1/20) = ~1 BTC
        // executionValue1 = Ceil(3 * 10/3) = 10 ETH. effectiveETH(~14) >= 10 ✓
        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 20 ether, 1 ether, 3);
        t2.feeBps = 1_500_000_000_000;
        Order memory m2 = _makeOrder(maker2, address(btc), address(eth), 3 ether, 10 ether, 4);
        m2.feeBps = 500_000_000_000;

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 2000 ether, m1, _signOrder(maker1PK, m1, sera), 20 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), 3 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 110, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 110, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Token conservation: total supply doesn't change (no mint/burn)
        assertEq(usdc.totalSupply(), totalUsdcBefore, "USDC total supply conserved");
        assertEq(eth.totalSupply(), totalEthBefore, "ETH total supply conserved");
        assertEq(btc.totalSupply(), totalBtcBefore, "BTC total supply conserved");

        // No dust
        _assertNoSeraDust(address(usdc), "USDC conservation");
        _assertNoSeraDust(address(eth), "ETH conservation");
        _assertNoSeraDust(address(btc), "BTC conservation");

        // Vault solvency
        address[] memory users = new address[](4);
        users[0] = taker; users[1] = maker1; users[2] = maker2; users[3] = owner;
        _assertVaultSolvent(address(usdc), users, "USDC conservation");
        _assertVaultSolvent(address(eth), users, "ETH conservation");
        _assertVaultSolvent(address(btc), users, "BTC conservation");
    }

    // ========================================================================
    // 9. PARTIAL FILL VIA ROUTE, THEN SECOND ROUTE
    // ========================================================================

    /// @notice Partial fill via first route, then remainder via second route
    function test_PartialFill_TwoRoutes() public {
        vm.prank(owner);
        sera.setSlippageShares(3000, 3000, 4000, 10000);

        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);

        // Giant taker order: 2000 USDC → 20 ETH
        Order memory takerBase = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        Order memory maker = _makeOrder(maker1, address(eth), address(usdc), 20 ether, 1600 ether, 2);

        // Route 1: fill 1000 USDC
        Order memory t1 = takerBase; // copy
        MatchData[] memory matches1 = new MatchData[](1);
        matches1[0] = MatchData(t1, bytes(""), 1000 ether, maker, _signOrder(maker1PK, maker, sera), 10 ether);
        bytes memory sig1 = _signIntent(takerPK, matches1[0].order0.fromToken, matches1[matches1.length - 1].order0.toToken, 0, 0, taker, 0, 111, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches1, sig1, IntentParams(matches1[0].order0.fromToken, matches1[matches1.length - 1].order0.toToken, 0, 0, taker, 0, 111, uint48(block.timestamp + 1 days)), uint8(matches1.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC after partial route 1");

        // Route 2: fill remaining 1000 USDC (different route hash since we re-finalize)
        Order memory t2 = _makeOrder(taker, address(usdc), address(eth), 2000 ether, 16 ether, 1);
        MatchData[] memory matches2 = new MatchData[](1);
        matches2[0] = MatchData(t2, bytes(""), 1000 ether, maker, _signOrder(maker1PK, maker, sera), 10 ether);
        bytes memory sig2 = _signIntent(takerPK, matches2[0].order0.fromToken, matches2[matches2.length - 1].order0.toToken, 0, 0, taker, 0, 112, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches2, sig2, IntentParams(matches2[0].order0.fromToken, matches2[matches2.length - 1].order0.toToken, 0, 0, taker, 0, 112, uint48(block.timestamp + 1 days)), uint8(matches2.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC after partial route 2");
        _assertNoSeraDust(address(eth), "ETH after both routes");

        // Taker's total rebate (makerBonus0 per fill: floor(200 * 3000/10000) = 60 USDC × 2 = 120)
        assertEq(sera.vault().balanceOf(address(usdc), taker), 120 ether, "Taker cumulative USDC rebate");
    }

    // ========================================================================
    // 10. 100% FEE + SPREAD — EXTREME
    // ========================================================================

    /// @notice 100% fee on both sides with spread — everything goes to protocol
    function test_NoDust_MaxFeesWithSpread() public {
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000); // 100% protocol

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // 100% fee, plus spread
        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t.feeBps = 100_000_000_000_000;
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);
        m.feeBps = 100_000_000_000_000;

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t, bytes(""), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);
        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 113, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 113, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC max-fees+spread");
        _assertNoSeraDust(address(eth), "ETH max-fees+spread");

        // Solvency & 100% extraction assertions
        address[] memory users = new address[](3);
        users[0] = taker; users[1] = maker1; users[2] = owner;
        _assertVaultSolvent(address(usdc), users, "USDC max-fees");
        _assertVaultSolvent(address(eth), users, "ETH max-fees");

        Vault v = sera.vault();
        assertGt(v.balanceOf(address(usdc), owner), 0, "Treasury exacted 100% USDC fee + spread");
        assertGt(v.balanceOf(address(eth), owner), 0, "Treasury exacted 100% ETH fee + spread");
    }

    // ========================================================================
    // 11. SAME MAKER IN TWO LEGS (shared liquidity)
    // ========================================================================

    /// @notice Same maker provides liquidity in both legs of a route
    function test_NoDust_SharedMaker_TwoLegs() public {
        vm.prank(owner);
        sera.setSlippageShares(2500, 2500, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);
        _mintAndDeposit(maker1, address(btc), 5 ether, sera); // SAME maker

        Order memory t1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        Order memory t2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory m2 = _makeOrder(maker1, address(btc), address(eth), 1 ether, 8 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, m1, _signOrder(maker1PK, m1, sera), 10 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker1PK, m2, sera), 1 ether);

        bytes memory sig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 114, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, 114, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        _assertNoSeraDust(address(usdc), "USDC shared-maker");
        _assertNoSeraDust(address(eth), "ETH shared-maker");
        _assertNoSeraDust(address(btc), "BTC shared-maker");
    }

    // ========================================================================
    // 12. DUST CHECK: STANDALONE MATCH HAS NO DUST (BASELINE)
    // ========================================================================

    /// @notice Standalone match should never have Sera dust (baseline)
    function test_NoDust_Standalone_Baseline() public {
        vm.prank(owner);
        sera.setSlippageShares(5000, 0, 5000, 10000);

        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory t = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 8 ether, 1);
        Order memory m = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 800 ether, 2);

        MatchData memory match_ = MatchData(t, _signOrder(takerPK, t, sera), 1000 ether, m, _signOrder(maker1PK, m, sera), 10 ether);

        vm.prank(executor);
        sera.matchOrders(match_, type(uint256).max);

        _assertNoSeraDust(address(usdc), "USDC standalone");
        _assertNoSeraDust(address(eth), "ETH standalone");
    }
}
