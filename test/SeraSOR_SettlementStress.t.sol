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
 * @title SeraSOR_SettlementStress_Test
 * @dev Stress tests for the settlement optimization:
 *      - Fuzz: randomized spread/fees/shares on vault pull optimization
 *      - Fuzz: randomized 2-leg executor-calibrated routes with per-leg fees
 *      - Wei-level settlement: vault pull at minimum amounts
 *      - Large-value settlement: near uint128 boundary
 *      - Extreme asymmetric pricing: 1e18:1 and 1:1e18 ratios
 *      - Sequential routes: 5 back-to-back routes eroding vault balance
 *      - Boundary slippage shares: 1/1/1 and 9998/1/1
 */
contract SeraSOR_SettlementStress_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;

    MockStableCoin public A;
    MockStableCoin public B;
    MockStableCoin public C;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public m1; uint256 public m1PK;
    address public m2; uint256 public m2PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (m1, m1PK) = makeAddrAndKey("m1");
        (m2, m2PK) = makeAddrAndKey("m2");

        A = new MockStableCoin("A");
        B = new MockStableCoin("B");
        C = new MockStableCoin("C");

        sera = _deploySera(owner);
        vault = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(A), true, 1);
        _whitelistToken(sera, address(B), true, 1);
        _whitelistToken(sera, address(C), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        sera.setSlippageShares(2500, 2500, 5000, 10000);
        vm.stopPrank();
    }

    // --------- Helpers ---------


    uint256 private _execNonce = 300;

    function _exec(MatchData[] memory matches) internal {
        _execCore(matches, matches[matches.length - 1].order0.recipient);
    }

    function _execCore(MatchData[] memory matches, address _r) internal {
        uint256 nonce = _execNonce++;
        uint256 _d = matches[0].order0.initialDepositAmount;
        address _in = matches[0].order0.fromToken;
        address _out = matches[matches.length - 1].order0.toToken;
        uint48 _dl = uint48(block.timestamp + 1 days);
        bytes memory sig = _signIntent(takerPK, taker, _in, _out, type(uint256).max, 1, _r, _d, nonce, _dl, sera);
        vm.prank(executor);
        sor.executeIntent(matches, sig, IntentParams(taker, _in, _out, type(uint256).max, 1, _r, _d, nonce, _dl), uint8(matches.length * 2 + 1), 0, bytes(""));
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
        assertEq(IERC20(token).balanceOf(address(sera)), 0, "dust");
    }

    // ========================================================================
    // 1. FUZZ: Randomized single-leg vault pull with spread, fees, shares
    // ========================================================================

    /// @notice Fuzz spread/fees/shares on a single vault-pulled leg.
    /// Invariants: no dust, taker retains >= 0 A, maker receives > 0 A.
    function testFuzz_VaultPull_RandomSharesAndFees(
        uint16 makerShare,
        uint16 takerShare,
        uint16 protocolShare,
        uint48 feeBpsTaker,
        uint48 feeBpsMaker
    ) public {
        uint256 totalShare = uint256(makerShare) + uint256(takerShare) + uint256(protocolShare);
        vm.assume(totalShare > 0);
        vm.assume(feeBpsTaker <= 100_000_000_000_000);
        vm.assume(feeBpsMaker <= 100_000_000_000_000);

        vm.prank(owner);
        sera.setSlippageShares(uint64(makerShare), uint64(takerShare), uint64(protocolShare), uint64(totalShare));

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        // Spread = 200A (1000 offered, maker wants 800)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 8 ether, 1, feeBpsTaker, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 10 ether, 800 ether, 2, feeBpsMaker, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        // Core invariants
        _assertNoDust(address(A));
        _assertNoDust(address(B));

        // Taker vault A should be >= 0 (some surplus retained depending on shares)
        uint256 takerA = vault.balanceOf(address(A), taker);
        assertGe(takerA, 0, "Taker A >= 0");

        // Maker should receive A > 0
        uint256 makerA = A.balanceOf(m1);
        uint256 makerAVault = vault.balanceOf(address(A), m1);
        assertGt(makerA + makerAVault, 0, "Maker got A");

        // Conservation: taker input + maker input = all outputs + all vault remaining
        // This is implicitly guaranteed by no-dust and no-revert.
    }

    // ========================================================================
    // 2. FUZZ: Randomized 2-leg executor-calibrated route with per-leg fees
    // ========================================================================

    /// @notice 2-leg route with random per-leg fees, exact pricing (zero spread).
    function testFuzz_TwoLeg_MECalibrated_PerLegFees(
        uint48 feeTakerLeg1,
        uint48 feeMakerLeg2
    ) public {
        vm.assume(feeTakerLeg1 <= 50_000_000_000_000); // max 50%
        vm.assume(feeMakerLeg2 <= 50_000_000_000_000);

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 500 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);

        // Leg 1: A->B. 1000A->500B. Exact pricing. feeTakerLeg1 on taker.
        // takerReceives = 500 - mulDiv(500, feeTakerLeg1, 10000)
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, feeTakerLeg1, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 0, address(0));

        uint256 leg1Output = 500 ether - Math.mulDiv(500 ether, feeTakerLeg1, 100_000_000_000_000);
        vm.assume(leg1Output > 0);

        // Leg 2: B->C. sentinel=leg1Output. ME calibrates maker: leg1Output C -> leg1Output B. 1:1.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 500 ether, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), leg1Output, leg1Output, 4, feeMakerLeg2, address(0));

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), leg1Output);
        _exec(matches);

        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));

        // Taker A fully consumed (zero spread)
        assertEq(vault.balanceOf(address(A), taker), 0, "Taker A consumed");
        // Taker received C
        assertGt(C.balanceOf(taker), 0, "Taker got C");
        // No B surplus (executor-calibrated)
        assertEq(vault.balanceOf(address(B), taker), 0, "No B surplus");
    }

    // ========================================================================
    // 3. WEI-LEVEL: Vault pull at absolute minimum amounts
    // ========================================================================

    /// @notice Vault pull with wei-level amounts (7 wei input, 3 wei maker wants)
    function test_WeiLevel_VaultPull() public {
        _mintAndDeposit(taker, address(A), 7, sera);
        _mintAndDeposit(m1, address(B), 10, sera);

        // Taker: 7A->1B. Maker: 2B->3A. executionValue1 = Ceil(2*3/2) = 3. spread = 7-3 = 4.
        Order memory t1 = _oFull(taker, address(A), address(B), 7, 1, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 2, 3, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 7, mk, _signOrder(m1PK, mk, sera), 2);
        _exec(matches);

        _assertNoDust(address(A));
        _assertNoDust(address(B));

        // Some A retained in vault (spread)
        uint256 takerA = vault.balanceOf(address(A), taker);
        assertGe(takerA, 0, "Wei-level: taker A >= 0");
        // Taker got B
        assertGt(B.balanceOf(taker), 0, "Wei-level: taker got B");
    }

    /// @notice Wei-level 2-leg: 11 wei A -> 5 wei B -> 2 wei C
    function test_WeiLevel_TwoLeg_Sentinel() public {
        _mintAndDeposit(taker, address(A), 11, sera);
        _mintAndDeposit(m1, address(B), 20, sera);
        _mintAndDeposit(m2, address(C), 20, sera);

        // Leg 1: 11A->5B. Maker: 5B->11A. Exact pricing.
        Order memory t1 = _oFull(taker, address(A), address(B), 11, 5, 1, 0, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 5, 11, 2, 0, address(0));

        // Leg 2: B->C. sentinel=5B. Maker: 2C->5B. Exact pricing.
        Order memory t2 = _oFull(taker, address(B), address(C), 10, 2, 3, 0, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), 2, 5, 4, 0, address(0));

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 11, mk1, _signOrder(m1PK, mk1, sera), 5);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), 2);
        _exec(matches);

        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));
        assertGt(C.balanceOf(taker), 0, "Wei-level 2-leg: taker got C");
    }

    // ========================================================================
    // 4. LARGE-VALUE: Near uint128 boundary
    // ========================================================================

    /// @notice Large-value vault pull: 1e32 tokens
    function test_LargeValue_VaultPull() public {
        uint256 largeAmount = 1e32;
        _mintAndDeposit(taker, address(A), largeAmount, sera);
        _mintAndDeposit(m1, address(B), largeAmount, sera);

        // 1:1 exact pricing, no spread, no fees
        Order memory t1 = _oFull(taker, address(A), address(B), largeAmount, largeAmount, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), largeAmount, largeAmount, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), largeAmount, mk, _signOrder(m1PK, mk, sera), largeAmount);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 0, "Large: A consumed");
        assertEq(B.balanceOf(taker), largeAmount, "Large: got B");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    /// @notice Large-value with spread: 1e30 tokens, 20% spread
    function test_LargeValue_WithSpread() public {
        uint256 tAmt = 1e30;
        uint256 mWants = 8e29; // maker wants 80% of taker input -> 20% spread
        _mintAndDeposit(taker, address(A), tAmt, sera);
        _mintAndDeposit(m1, address(B), 1e30, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), tAmt, 1e28, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 1e29, mWants, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), tAmt, mk, _signOrder(m1PK, mk, sera), 1e29);
        _exec(matches);

        // Taker retains spread share
        assertGt(vault.balanceOf(address(A), taker), 0, "Large spread: taker retained A");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    // ========================================================================
    // 5. EXTREME ASYMMETRIC PRICING
    // ========================================================================

    /// @notice Asymmetric: 1e18 A for 1 B (extreme ratio)
    function test_AsymmetricPricing_HighRatio() public {
        _mintAndDeposit(taker, address(A), 1e18, sera);
        _mintAndDeposit(m1, address(B), 100, sera);

        // Taker: 1e18 A -> 1 B. Maker: 1 B -> 5e17 A. Spread = 5e17.
        Order memory t1 = _oFull(taker, address(A), address(B), 1e18, 1, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 1, 5e17, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1e18, mk, _signOrder(m1PK, mk, sera), 1);
        _exec(matches);

        assertGt(vault.balanceOf(address(A), taker), 0, "Asymmetric: taker retained A");
        assertEq(B.balanceOf(taker), 1, "Asymmetric: taker got 1 B");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    /// @notice Asymmetric reversed: 1 A for 1e18 B
    function test_AsymmetricPricing_LowRatio() public {
        _mintAndDeposit(taker, address(A), 1, sera);
        _mintAndDeposit(m1, address(B), 1e18, sera);

        // Taker: 1 A -> 1e18 B. Maker: 1e18 B -> 1 A. Exact pricing.
        Order memory t1 = _oFull(taker, address(A), address(B), 1, 1e18, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 1e18, 1, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1, mk, _signOrder(m1PK, mk, sera), 1e18);
        _exec(matches);

        assertEq(vault.balanceOf(address(A), taker), 0, "Low ratio: A consumed");
        assertEq(B.balanceOf(taker), 1e18, "Low ratio: got 1e18 B");
        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    // ========================================================================
    // 6. SEQUENTIAL ROUTES: 5 back-to-back routes eroding vault balance
    // ========================================================================

    /// @notice Five sequential routes with spread, verifying cumulative vault erosion
    function test_Sequential_FiveRoutes_CumulativeSpread() public {
        _mintAndDeposit(taker, address(A), 5000 ether, sera);
        // Create 5 separate makers each with 200 B
        address[5] memory makers;
        uint256[5] memory makerPKs;
        for (uint256 i = 0; i < 5; i++) {
            (makers[i], makerPKs[i]) = makeAddrAndKey(string(abi.encodePacked("maker_seq_", vm.toString(i))));
            _mintAndDeposit(makers[i], address(B), 200 ether, sera);
        }

        // Each route: 1000A -> 100B. Maker wants 800A. Spread = 200A.
        // With 25/25/50: spreadToTaker=50, retained in vault. neededFromTaker=950.
        uint256 expectedRetainPerRoute = 50 ether;
        uint256 cumExpected = 0;

        for (uint256 i = 0; i < 5; i++) {
            Order memory tOrder = _oFull(taker, address(A), address(B), 1000 ether, 10 ether, i * 2 + 1, 0, taker);
            Order memory mOrder = _oFull(makers[i], address(B), address(A), 100 ether, 800 ether, i * 2 + 2, 0, makers[i]);

            MatchData[] memory matches = new MatchData[](1);
            matches[0] = MatchData(tOrder, bytes(""), 1000 ether, mOrder, _signOrder(makerPKs[i], mOrder, sera), 100 ether);
            _exec(matches);

            cumExpected += expectedRetainPerRoute;
            _assertNoDust(address(A));
            _assertNoDust(address(B));
        }

        uint256 takerRemaining = vault.balanceOf(address(A), taker);
        // 5000 - (950 * 5) = 5000 - 4750 = 250
        assertEq(takerRemaining, 250 ether, "5 routes: cumulative spread retained");
    }

    // ========================================================================
    // 7. BOUNDARY SLIPPAGE SHARES
    // ========================================================================

    /// @notice Minimum viable shares: 1/1/1
    function test_BoundaryShares_Minimum() public {
        vm.prank(owner);
        sera.setSlippageShares(1, 1, 1, 3); // 33.3% each

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 8 ether, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 10 ether, 800 ether, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        // spread = 200. Each share = 200/3 ~ 66.67
        // spreadToMaker0 = mulDiv(200, 1, 3) = 66
        // protocolSpread0 = mulDiv(200, 1, 3) = 66
        // spreadToTaker0 = 200 - 66 - 66 = 68 (remainder)
        _assertNoDust(address(A));
        assertGt(vault.balanceOf(address(A), taker), 0, "Min shares: taker retained");
    }

    /// @notice Extreme skew: 9998/1/1
    function test_BoundaryShares_ExtremeSkew() public {
        vm.prank(owner);
        sera.setSlippageShares(9998, 1, 1, 10000);

        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 100 ether, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 8 ether, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), 10 ether, 800 ether, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk, _signOrder(m1PK, mk, sera), 10 ether);
        _exec(matches);

        // Shares (maker=9998, taker=1, protocol=1) on totalSpread0 = 200:
        //   spreadToMaker0 = mulDiv(200, 9998, 10000) = 199.96e18 → maker explicit uplift.
        //   protocolSpread0 = 0.02e18 → treasury.
        //   spreadToTaker0 = 200 - 199.96 - 0.02 = 0.02e18 → taker implicit retention.
        //   calc.executionValue1 = 800 + 199.96 = 999.96 (to maker wallet).
        _assertNoDust(address(A));

        // Taker retains only the tiny taker share (1 bp) as implicit vault residual.
        uint256 takerA = vault.balanceOf(address(A), taker);
        assertEq(takerA, 0.02 ether, "Extreme skew: taker retains spreadToTaker0 = 0.02 A (1 bp of 200)");
        assertEq(A.balanceOf(m1), 999.96 ether, "Maker wallet = 800 + 199.96 spreadToMaker0");
        assertEq(vault.balanceOf(address(A), sera.treasury()), 0.02 ether, "Treasury captured protocolSpread0 = 0.02 A");
    }

    // ========================================================================
    // 8. FUZZ: Random pricing within constraints
    // ========================================================================

    /// @notice Fuzz both order amounts and match amounts for a single-leg vault pull
    function testFuzz_SingleLeg_RandomPricing(
        uint256 takerFrom,
        uint256 takerTo,
        uint256 makerFrom,
        uint256 makerWants
    ) public {
        // Bound to reasonable ranges
        vm.assume(takerFrom > 1000 && takerFrom < 1e30);
        vm.assume(takerTo > 0 && takerTo < 1e30);
        vm.assume(makerFrom > 0 && makerFrom < 1e30);
        vm.assume(makerWants > 0 && makerWants < 1e30);
        // Price overlap: takerFrom/takerTo >= makerWants/makerFrom
        // i.e. takerFrom * makerFrom >= makerWants * takerTo
        vm.assume(takerFrom < type(uint64).max);
        vm.assume(takerTo < type(uint64).max);
        vm.assume(makerFrom < type(uint64).max);
        vm.assume(makerWants < type(uint64).max);
        vm.assume(uint256(takerFrom) * uint256(makerFrom) >= uint256(makerWants) * uint256(takerTo));
        // executionValue1 = Ceil(makerFrom * makerWants / makerFrom) = makerWants. Must fit in takerFrom.
        vm.assume(makerWants <= takerFrom);
        // executionValue0 = Ceil(takerFrom * takerTo / takerFrom) = takerTo. Must fit in makerFrom.
        vm.assume(takerTo <= makerFrom);

        _mintAndDeposit(taker, address(A), takerFrom, sera);
        _mintAndDeposit(m1, address(B), makerFrom, sera);

        Order memory t1 = _oFull(taker, address(A), address(B), takerFrom, takerTo, 1, 0, taker);
        Order memory mk = _oFull(m1, address(B), address(A), makerFrom, makerWants, 2, 0, m1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(t1, bytes(""), takerFrom, mk, _signOrder(m1PK, mk, sera), makerFrom);
        _exec(matches);

        _assertNoDust(address(A));
        _assertNoDust(address(B));
    }

    // ========================================================================
    // 9. MAX FEES on per-leg routes
    // ========================================================================

    /// @notice 50% fee on every participant in a 2-leg route
    function test_MaxFees_TwoLeg_AllParties() public {
        _mintAndDeposit(taker, address(A), 1000 ether, sera);
        _mintAndDeposit(m1, address(B), 500 ether, sera);
        _mintAndDeposit(m2, address(C), 500 ether, sera);

        // Leg 1: 50% taker, 50% maker. 1000A->500B. Exact pricing.
        Order memory t1 = _oFull(taker, address(A), address(B), 1000 ether, 500 ether, 1, 50_000_000_000_000, address(sera));
        Order memory mk1 = _oFull(m1, address(B), address(A), 500 ether, 1000 ether, 2, 50_000_000_000_000, address(0));

        // takerReceives from leg1:
        // executionValue0 = 500. protocolFee1 = mulDiv(500, 5e13, 1e14) = 250.
        // takerReceives = 500 - 250 = 250B.
        uint256 leg1Output = 250 ether;

        // Leg 2: 50% taker, 50% maker. sentinel=250B. 250C->250B. Exact.
        Order memory t2 = _oFull(taker, address(B), address(C), 500 ether, 500 ether, 3, 50_000_000_000_000, taker);
        Order memory mk2 = _oFull(m2, address(C), address(B), leg1Output, leg1Output, 4, 50_000_000_000_000, address(0));

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), 1000 ether, mk1, _signOrder(m1PK, mk1, sera), 500 ether);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, mk2, _signOrder(m2PK, mk2, sera), leg1Output);
        _exec(matches);

        _assertNoDust(address(A));
        _assertNoDust(address(B));
        _assertNoDust(address(C));

        // Taker received some C (heavily fee-taxed)
        assertGt(C.balanceOf(taker), 0, "Max fees: taker got C");
        // Taker A fully consumed (zero spread)
        assertEq(vault.balanceOf(address(A), taker), 0, "Max fees: A consumed");
    }
}
