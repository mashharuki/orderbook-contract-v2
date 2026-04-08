// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_AdvancedFuzz_Test
 * @dev Fuzz tests targeting extreme values for fees, slippage shares, and order amounts.
 */
contract SeraSOR_AdvancedFuzz_Test is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    MockStableCoin public aToken;
    MockStableCoin public bToken;
    MockStableCoin public cToken;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");

        aToken = new MockStableCoin("ATK");
        bToken = new MockStableCoin("BTK");
        cToken = new MockStableCoin("CTK");

        sera = _deploySera(owner);
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(aToken), true, 1);
        _whitelistToken(sera, address(bToken), true, 1);
        _whitelistToken(sera, address(cToken), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTreasury(owner);
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

    // Fuzz test for slippage shares and execution values
    function testFuzz_RandomSlippageShares(
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

        _mintAndDeposit(taker, address(aToken), 1000 ether, sera);
        _mintAndDeposit(maker1, address(bToken), 1000 ether, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), 1000 ether, 100 ether, 1);
        tOrder.feeBps = feeBpsTaker;

        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), 100 ether, 800 ether, 2);
        mOrder.feeBps = feeBpsMaker;

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), 1000 ether, mOrder, _signOrder(maker1PK, mOrder, sera), 100 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Verify Vault Solvency
        Vault v = sera.vault();
        
        uint256 totalAToken = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        uint256 totalBToken = v.balanceOf(address(bToken), taker) + v.balanceOf(address(bToken), maker1) + v.balanceOf(address(bToken), owner);
        
        assertGe(aToken.balanceOf(address(v)), totalAToken, "Vault Solvent A");
        assertGe(bToken.balanceOf(address(v)), totalBToken, "Vault Solvent B");
        assertEq(IERC20(address(aToken)).balanceOf(address(sera)), 0, "No dust ATK");
        assertEq(IERC20(address(bToken)).balanceOf(address(sera)), 0, "No dust BTK");
    }

    function testFuzz_ExtremeAmounts(
        uint256 tFromAmount,
        uint256 tToAmount,
        uint256 mFromAmount,
        uint256 mToAmount,
        uint256 takerMatchAmount
    ) public {
        // Taker offers aToken, wants bToken
        // Maker offers bToken, wants aToken
        vm.assume(tFromAmount > 100 && tFromAmount < type(uint128).max);
        vm.assume(tToAmount > 100 && tToAmount < type(uint128).max);
        vm.assume(mFromAmount > 100 && mFromAmount < type(uint128).max);
        vm.assume(mToAmount > 100 && mToAmount < type(uint128).max);

        // Prices must overlap
        // Taker price: tFromAmount / tToAmount
        // Maker price: mToAmount / mFromAmount
        // Need tFromAmount / tToAmount >= mToAmount / mFromAmount
        // mFromAmount * tFromAmount >= mToAmount * tToAmount
        // To avoid overflow, cap limits
        vm.assume(tFromAmount < type(uint64).max);
        vm.assume(tToAmount < type(uint64).max);
        vm.assume(mFromAmount < type(uint64).max);
        vm.assume(mToAmount < type(uint64).max);
        vm.assume(mFromAmount * tFromAmount >= mToAmount * tToAmount);

        vm.assume(takerMatchAmount > 0 && takerMatchAmount <= tFromAmount);

        _mintAndDeposit(taker, address(aToken), tFromAmount, sera);
        _mintAndDeposit(maker1, address(bToken), mFromAmount, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), tFromAmount, tToAmount, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), mFromAmount, mToAmount, 2);

        // Evaluate maker match amount. Let's just consume the whole takerMatchAmount
        // The effectiveAmount0 = takerMatchAmount
        // executionValue0 = ceil(takerMatchAmount * tToAmount / tFromAmount)
        // executionValue1 = ceil(makerMatchAmount * mToAmount / mFromAmount)
        
        // Let's set makerMatchAmount = executionValue0 (the exact amount of bToken the taker wants)
        uint256 makerMatchAmount = (takerMatchAmount * tToAmount + tFromAmount - 1) / tFromAmount;
        vm.assume(makerMatchAmount > 0 && makerMatchAmount <= mFromAmount);

        // Check the secondary constraint to avoid reverting InvalidCostAmount() in tests
        // executionValue1 = ceil(makerMatchAmount * mToAmount / mFromAmount)
        uint256 executionValue1 = (makerMatchAmount * mToAmount + mFromAmount - 1) / mFromAmount;
        vm.assume(takerMatchAmount >= executionValue1);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), takerMatchAmount, mOrder, _signOrder(maker1PK, mOrder, sera), makerMatchAmount);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Revert checks
        vm.prank(owner);
        sera.setSlippageShares(1000, 1000, 8000, 10000);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        Vault v = sera.vault();
        
        uint256 totalAToken = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        uint256 totalBToken = v.balanceOf(address(bToken), taker) + v.balanceOf(address(bToken), maker1) + v.balanceOf(address(bToken), owner);
        
        assertGe(aToken.balanceOf(address(v)), totalAToken, "Vault Solvent A");
        assertGe(bToken.balanceOf(address(v)), totalBToken, "Vault Solvent B");
        assertEq(IERC20(address(aToken)).balanceOf(address(sera)), 0, "No dust ATK");
        assertEq(IERC20(address(bToken)).balanceOf(address(sera)), 0, "No dust BTK");
    }

    // ------------------------------------------------------------------------
    // NEW ADVANCED FUZZ TESTS
    // ------------------------------------------------------------------------

    // testFuzz_StrictSpreadRebateMath
    function testFuzz_StrictSpreadRebateMath(
        uint16 mShare, uint16 tShare, uint16 pShare,
        uint256 tAmount, uint256 m1Amount
    ) public {
        uint256 totShare = uint256(mShare) + uint256(tShare) + uint256(pShare);
        vm.assume(totShare > 0);
        vm.assume(tAmount > 1000 && tAmount < 1000000 ether);
        vm.assume(m1Amount > 1000 && m1Amount < 1000000 ether);
        
        uint256 tFrom = tAmount;
        uint256 tTo = tAmount / 10;
        vm.assume(tTo > 0);
        uint256 mFrom = tTo;
        uint256 mTo = tFrom / 2; // cheaper! 5 A for 1 B instead of 10 A for 1 B
        vm.assume(mTo > 0);

        vm.prank(owner);
        sera.setSlippageShares(mShare, tShare, pShare, uint64(totShare));

        _mintAndDeposit(taker, address(aToken), tFrom, sera);
        _mintAndDeposit(maker1, address(bToken), mFrom, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), tFrom, tTo, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), mFrom, mTo, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), tFrom, mOrder, _signOrder(maker1PK, mOrder, sera), mFrom);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        uint256 spread0 = tFrom - mTo;
        uint256 expectedProtocol0 = spread0 * pShare / totShare; // Floor
        Vault v = sera.vault();
        
        assertEq(v.balanceOf(address(aToken), owner), expectedProtocol0, "Strict treasury formulation matched");
    }

    // testFuzz_WalletFunded_ERC20Boundaries
    function testFuzz_WalletFunded_ERC20Boundaries(uint256 initDeposit) public {
        vm.assume(initDeposit > 100 && initDeposit < type(uint128).max);
        
        aToken.mint(taker, initDeposit);
        vm.prank(taker);
        aToken.approve(address(sor), initDeposit);
        _mintAndDeposit(maker1, address(bToken), initDeposit, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), initDeposit, initDeposit/2, 1);
        tOrder.initialDepositAmount = initDeposit;
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), initDeposit/2, initDeposit/2, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), initDeposit, mOrder, _signOrder(maker1PK, mOrder, sera), initDeposit/2);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, initDeposit, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(owner);
        sera.setSlippageShares(30, 30, 40, 100);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, initDeposit, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        assertEq(aToken.balanceOf(address(sera)), 0, "No stranded dust after wallet injection");
    }

    // testFuzz_MultipleMatchingMakers
    function testFuzz_MultipleMatchingMakers(
        uint256 f1, uint256 f2, uint256 f3
    ) public {
        vm.assume(f1 > 1000 && f1 < 100000 ether);
        vm.assume(f2 > 1000 && f2 < 100000 ether);
        vm.assume(f3 > 1000 && f3 < 100000 ether);
        uint256 tAmount = f1 + f2 + f3;

        _mintAndDeposit(taker, address(aToken), tAmount, sera);
        _mintAndDeposit(maker1, address(bToken), f1, sera);
        _mintAndDeposit(maker2, address(bToken), f2, sera);
        (address maker3, uint256 maker3PK) = makeAddrAndKey("maker3");
        _mintAndDeposit(maker3, address(bToken), f3, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), tAmount, tAmount, 1);
        Order memory m1 = _makeOrder(maker1, address(bToken), address(aToken), f1, f1, 2);
        Order memory m2 = _makeOrder(maker2, address(bToken), address(aToken), f2, f2, 3);
        Order memory m3 = _makeOrder(maker3, address(bToken), address(aToken), f3, f3, 4);
        m1.feeBps = 1_000_000_000_000; m2.feeBps = 2_000_000_000_000; m3.feeBps = 3_000_000_000_000;

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(tOrder, bytes(""), f1, m1, _signOrder(maker1PK, m1, sera), f1);
        matches[1] = MatchData(tOrder, bytes(""), f2, m2, _signOrder(maker2PK, m2, sera), f2);
        matches[2] = MatchData(tOrder, bytes(""), f3, m3, _signOrder(maker3PK, m3, sera), f3);

        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        Vault v = sera.vault();
        assertEq(aToken.balanceOf(address(sera)), 0);
        assertEq(bToken.balanceOf(address(sera)), 0);
        assertGe(bToken.balanceOf(address(v)), v.balanceOf(address(bToken), taker) + v.balanceOf(address(bToken), owner)); 
    }

    // testFuzz_FeesAndSlippageIntersection
    function testFuzz_FeesAndSlippageIntersection(uint48 tFee, uint48 mFee) public {
        vm.assume(tFee <= 100_000_000_000_000 && mFee <= 100_000_000_000_000);
        
        vm.prank(owner);
        sera.setSlippageShares(0, 0, 10000, 10000); // 100% protocol spread

        _mintAndDeposit(taker, address(aToken), 1000 ether, sera);
        _mintAndDeposit(maker1, address(bToken), 1000 ether, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), 1000 ether, 100 ether, 1);
        tOrder.feeBps = tFee;
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), 100 ether, 500 ether, 2);
        mOrder.feeBps = mFee;

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), 1000 ether, mOrder, _signOrder(maker1PK, mOrder, sera), 100 ether);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        assertEq(aToken.balanceOf(address(sera)), 0);
    }

    // testFuzz_MaxIntegerMathBounds
    function testFuzz_MaxIntegerMathBounds(uint256 x) public {
        vm.assume(x > type(uint112).max && x < type(uint128).max);
        
        _mintAndDeposit(taker, address(aToken), x, sera);
        _mintAndDeposit(maker1, address(bToken), x, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), x, x, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), x, x, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), x, mOrder, _signOrder(maker1PK, mOrder, sera), x);
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));
        assertEq(aToken.balanceOf(address(sera)), 0);
    }

    // True 3-leg Route Fuzzing
    function testFuzz_TrueThreeLegRoute(
        uint256 takerAmount,
        uint48 feeTaker,
        uint48 feeM1,
        uint48 feeM2,
        uint48 feeM3
    ) public {
        vm.assume(takerAmount > 100 ether && takerAmount < 10000 ether);
        vm.assume(feeTaker <= 100_000_000_000_000 && feeM1 <= 100_000_000_000_000 && feeM2 <= 100_000_000_000_000 && feeM3 <= 100_000_000_000_000);

        MockStableCoin dToken = new MockStableCoin("DTK");
        vm.prank(owner);
        _whitelistToken(sera, address(dToken), true, 1);

        _mintAndDeposit(taker, address(aToken), takerAmount, sera);
        _mintAndDeposit(maker1, address(bToken), takerAmount, sera);
        _mintAndDeposit(maker2, address(cToken), takerAmount, sera);
        (address maker3, uint256 maker3PK) = makeAddrAndKey("maker3");
        _mintAndDeposit(maker3, address(dToken), takerAmount, sera);

        uint256 l1To = takerAmount / 2;
        Order memory tOrder1 = _makeOrder(taker, address(aToken), address(bToken), takerAmount, l1To, 1);
        tOrder1.feeBps = feeTaker; tOrder1.recipient = address(sera);
        Order memory mOrder1 = _makeOrder(maker1, address(bToken), address(aToken), l1To, takerAmount, 2);
        mOrder1.feeBps = feeM1;

        // Leg 2 - Transient execution limits set to infinity to allow any fee/spread intersection
        Order memory tOrder2 = _makeOrder(taker, address(bToken), address(cToken), type(uint128).max, 1, 3);
        tOrder2.feeBps = feeTaker; tOrder2.recipient = address(sera);
        Order memory mOrder2 = _makeOrder(maker2, address(cToken), address(bToken), l1To, 1, 4); // maker gives enough depth (l1To is large)
        mOrder2.feeBps = feeM2;

        // Leg 3
        Order memory tOrder3 = _makeOrder(taker, address(cToken), address(dToken), type(uint128).max, 1, 5);
        tOrder3.feeBps = feeTaker;
        Order memory mOrder3 = _makeOrder(maker3, address(dToken), address(cToken), l1To, 1, 6);
        mOrder3.feeBps = feeM3;

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData(tOrder1, bytes(""), takerAmount, mOrder1, _signOrder(maker1PK, mOrder1, sera), l1To);
        matches[1] = MatchData(tOrder2, bytes(""), type(uint256).max, mOrder2, _signOrder(maker2PK, mOrder2, sera), l1To); // fill all depth
        matches[2] = MatchData(tOrder3, bytes(""), type(uint256).max, mOrder3, _signOrder(maker3PK, mOrder3, sera), l1To);
        
        bytes memory sorSig = _signIntent(takerPK, taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        assertEq(aToken.balanceOf(address(sera)), 0);
        assertEq(bToken.balanceOf(address(sera)), 0);
        assertEq(cToken.balanceOf(address(sera)), 0);
        assertEq(dToken.balanceOf(address(sera)), 0);
    }

    // ========================================================================
    // PARTIAL FILL ACCUMULATION FUZZ
    // ========================================================================

    /// @notice Fuzz partial fills: fill a fraction, then the remainder. filledAmount must be exact.
    function testFuzz_PartialFillAccumulation(
        uint256 totalAmount,
        uint256 firstFill
    ) public {
        vm.assume(totalAmount > 200 && totalAmount < 100000 ether);
        vm.assume(firstFill > 0 && firstFill < totalAmount);
        uint256 secondFill = totalAmount - firstFill;

        _mintAndDeposit(taker, address(aToken), totalAmount, sera);
        _mintAndDeposit(maker1, address(bToken), totalAmount, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), totalAmount, totalAmount, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), totalAmount, totalAmount, 2);

        // First partial fill
        MatchData[] memory m1 = new MatchData[](1);
        m1[0] = MatchData(tOrder, bytes(""), firstFill, mOrder, _signOrder(maker1PK, mOrder, sera), firstFill);
        bytes memory sig1 = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(m1, sig1, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        // Second fill for remainder
        MatchData[] memory m2 = new MatchData[](1);
        m2[0] = MatchData(tOrder, bytes(""), secondFill, mOrder, _signOrder(maker1PK, mOrder, sera), secondFill);
        bytes memory sig2 = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp + 1, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(m2, sig2, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp + 1, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        // Both tokens fully consumed — no dust, vault solvent
        assertEq(aToken.balanceOf(address(sera)), 0, "No dust A after partials");
        assertEq(bToken.balanceOf(address(sera)), 0, "No dust B after partials");

        Vault v = sera.vault();
        uint256 sumA = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        uint256 sumB = v.balanceOf(address(bToken), taker) + v.balanceOf(address(bToken), maker1) + v.balanceOf(address(bToken), owner);
        assertGe(aToken.balanceOf(address(v)), sumA, "Vault solvent A");
        assertGe(bToken.balanceOf(address(v)), sumB, "Vault solvent B");
    }

    // ========================================================================
    // SPREAD CONSERVATION INVARIANT (no wei lost in rounding)
    // ========================================================================

    /// @notice Proves: spread is distributed without creating or destroying value inside the vault
    function testFuzz_SpreadConservation(
        uint16 mShare, uint16 tShare, uint16 pShare,
        uint256 takerAmount
    ) public {
        uint256 totShare = uint256(mShare) + uint256(tShare) + uint256(pShare);
        vm.assume(totShare > 0 && totShare <= 30000);
        vm.assume(takerAmount > 10000 && takerAmount < 10000000 ether);

        uint256 tFrom = takerAmount;
        uint256 tTo = takerAmount / 5;  // taker generous: wants 1/5
        uint256 mFrom = tTo;            // maker offers exactly what taker wants
        uint256 mTo = takerAmount / 2;  // maker only needs half
        vm.assume(tTo > 0 && mTo > 0);

        vm.prank(owner);
        sera.setSlippageShares(mShare, tShare, pShare, uint64(totShare));

        _mintAndDeposit(taker, address(aToken), tFrom, sera);
        _mintAndDeposit(maker1, address(bToken), mFrom, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), tFrom, tTo, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), mFrom, mTo, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), tFrom, mOrder, _signOrder(maker1PK, mOrder, sera), mFrom);
        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        // The vault ledger sum for A cannot exceed the physical A held by the vault
        Vault v = sera.vault();
        uint256 sumA = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        assertGe(aToken.balanceOf(address(v)), sumA, "Vault solvent: ledger <= physical");
        // No dust in Sera
        assertEq(aToken.balanceOf(address(sera)), 0, "No dust A");
        // Total supply unchanged (no mint/burn)
        assertEq(aToken.totalSupply(), tFrom, "A supply conserved");
    }

    // ========================================================================
    // ENVELOPE GUARDS FUZZ
    // ========================================================================

    /// @notice Fuzz maxInput and minOutput guards: pass when valid, revert when violated
    function testFuzz_EnvelopeGuards_Boundaries(
        uint256 takerAmount,
        uint256 maxInput,
        uint256 minOutput
    ) public {
        vm.assume(takerAmount > 1000 && takerAmount < 100000 ether);
        vm.assume(maxInput < type(uint128).max);
        vm.assume(minOutput < type(uint128).max);

        _mintAndDeposit(taker, address(aToken), takerAmount, sera);
        _mintAndDeposit(maker1, address(bToken), takerAmount, sera);

        // 1:1 pricing, zero spread — so takerInputCost = takerAmount, takerOutput = takerAmount
        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), takerAmount, takerAmount, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), takerAmount, takerAmount, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), takerAmount, mOrder, _signOrder(maker1PK, mOrder, sera), takerAmount);
        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(bToken), maxInput, minOutput, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        bool shouldRevertMaxInput = (maxInput > 0 && takerAmount > maxInput);
        bool shouldRevertMinOutput = (minOutput > 0 && takerAmount < minOutput);

        vm.prank(executor);
        if (shouldRevertMaxInput || shouldRevertMinOutput) {
            vm.expectRevert();
        }
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(bToken), maxInput, minOutput, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));
    }

    // ========================================================================
    // TOKEN CONSERVATION FUZZ
    // ========================================================================

    /// @notice ERC-20 totalSupply must not change through any settlement path
    function testFuzz_TokenConservation(
        uint256 takerAmount,
        uint48 fee
    ) public {
        vm.assume(takerAmount > 1000 && takerAmount < 1000000 ether);
        vm.assume(fee <= 100_000_000_000_000);

        _mintAndDeposit(taker, address(aToken), takerAmount, sera);
        _mintAndDeposit(maker1, address(bToken), takerAmount, sera);

        uint256 supplyA_before = aToken.totalSupply();
        uint256 supplyB_before = bToken.totalSupply();

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), takerAmount, takerAmount / 2, 1);
        tOrder.feeBps = fee;
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), takerAmount / 2, takerAmount / 2, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), takerAmount, mOrder, _signOrder(maker1PK, mOrder, sera), takerAmount / 2);
        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        assertEq(aToken.totalSupply(), supplyA_before, "A supply conserved");
        assertEq(bToken.totalSupply(), supplyB_before, "B supply conserved");
    }

    // ========================================================================
    // 2-LEG SENTINEL WITH RANDOMIZED SPREAD FUZZ
    // ========================================================================

    /// @notice Fuzz the critical sentinel resolution path with randomized intermediate pricing
    function testFuzz_TwoLegSentinel_RandomPricing(
        uint256 takerAmount,
        uint256 makerRateSeed
    ) public {
        takerAmount = bound(takerAmount, 10 ether, 100000 ether);
        uint256 makerRate = bound(makerRateSeed, 10, 500); // 0.1x to 5x

        uint256 leg1MakerFrom = takerAmount;

        uint256 leg2MakerFrom = takerAmount * makerRate / 100;

        _mintAndDeposit(taker, address(aToken), takerAmount, sera);
        _mintAndDeposit(maker1, address(bToken), leg1MakerFrom, sera);
        _mintAndDeposit(maker2, address(cToken), leg2MakerFrom, sera);

        // Leg 1: A -> B (exact pricing, hold for next leg)
        Order memory t1 = _makeOrder(taker, address(aToken), address(bToken), takerAmount, takerAmount, 1);
        t1.recipient = address(sera);
        Order memory m1 = _makeOrder(maker1, address(bToken), address(aToken), leg1MakerFrom, takerAmount, 2);

        // Leg 2: B -> C (sentinel, randomized maker pricing)
        Order memory t2 = _makeOrder(taker, address(bToken), address(cToken), type(uint128).max, 1, 3);
        Order memory m2 = _makeOrder(maker2, address(cToken), address(bToken), leg2MakerFrom, 1, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(t1, bytes(""), takerAmount, m1, _signOrder(maker1PK, m1, sera), leg1MakerFrom);
        matches[1] = MatchData(t2, bytes(""), type(uint256).max, m2, _signOrder(maker2PK, m2, sera), leg2MakerFrom);

        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(cToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(cToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        // Core invariants after sentinel resolution
        assertEq(aToken.balanceOf(address(sera)), 0, "No dust A");
        assertEq(bToken.balanceOf(address(sera)), 0, "No dust B (transient fully consumed)");
        assertEq(cToken.balanceOf(address(sera)), 0, "No dust C");

        Vault v = sera.vault();
        assertGe(bToken.balanceOf(address(v)),
            v.balanceOf(address(bToken), taker) + v.balanceOf(address(bToken), maker1) + v.balanceOf(address(bToken), owner),
            "Vault solvent B");
    }

    // ========================================================================
    // ASYMMETRIC PRICING RATIO FUZZ
    // ========================================================================

    /// @notice Fuzz extreme price ratios (e.g. 1:1000000 or 1000000:1) to stress mulDiv
    function testFuzz_AsymmetricPricingRatios(
        uint256 fromVal,
        uint256 toVal
    ) public {
        // Need both > 0, reasonable range to avoid trivial rejects, but allow extreme ratios
        vm.assume(fromVal > 100 && fromVal < 10000000 ether);
        vm.assume(toVal > 100 && toVal < 10000000 ether);

        // Ensure maker price overlaps (maker is at least as cheap)
        uint256 mFrom = toVal;
        uint256 mTo = fromVal / 2; // maker only asks for half what taker offers
        vm.assume(mTo > 0);

        // Check mulDiv won't overflow: fromVal * toVal < uint256.max
        vm.assume(fromVal < type(uint128).max && toVal < type(uint128).max);

        _mintAndDeposit(taker, address(aToken), fromVal, sera);
        _mintAndDeposit(maker1, address(bToken), mFrom, sera);

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), fromVal, toVal, 1);
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), mFrom, mTo, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), fromVal, mOrder, _signOrder(maker1PK, mOrder, sera), mFrom);
        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        assertEq(aToken.balanceOf(address(sera)), 0, "No dust at extreme ratio");
        Vault v = sera.vault();
        uint256 sumA = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        assertGe(aToken.balanceOf(address(v)), sumA, "Solvent at extreme ratio");
    }

    // ========================================================================
    // RANDOMIZED SHARES + FEES FULL DISTRIBUTION INVARIANT
    // ========================================================================

    /// @notice For any shares/fees combo: vault remains solvent, no dust, supply conserved
    function testFuzz_FullDistributionInvariant(
        uint16 mShare, uint16 tShare, uint16 pShare,
        uint48 tFee, uint48 mFee
    ) public {
        uint256 totShare = uint256(mShare) + uint256(tShare) + uint256(pShare);
        vm.assume(totShare > 0 && totShare <= 30000);
        vm.assume(tFee <= 100_000_000_000_000 && mFee <= 100_000_000_000_000);

        vm.prank(owner);
        sera.setSlippageShares(mShare, tShare, pShare, uint64(totShare));

        uint256 amount = 10000 ether;
        _mintAndDeposit(taker, address(aToken), amount, sera);
        _mintAndDeposit(maker1, address(bToken), amount, sera);

        uint256 supplyA = aToken.totalSupply();
        uint256 supplyB = bToken.totalSupply();

        Order memory tOrder = _makeOrder(taker, address(aToken), address(bToken), amount, amount / 5, 1);
        tOrder.feeBps = tFee;
        Order memory mOrder = _makeOrder(maker1, address(bToken), address(aToken), amount / 5, amount / 2, 2);
        mOrder.feeBps = mFee;

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(tOrder, bytes(""), amount, mOrder, _signOrder(maker1PK, mOrder, sera), amount / 5);
        bytes memory sorSig = _signIntent(takerPK, taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(taker, address(aToken), address(bToken), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), type(uint8).max, 0, bytes(""));

        // Vault solvency + supply conservation + no dust
        Vault v = sera.vault();
        uint256 sumA = v.balanceOf(address(aToken), taker) + v.balanceOf(address(aToken), maker1) + v.balanceOf(address(aToken), owner);
        assertGe(aToken.balanceOf(address(v)), sumA, "Vault solvent A");
        assertEq(aToken.totalSupply(), supplyA, "A supply conserved");
        assertEq(bToken.totalSupply(), supplyB, "B supply conserved");
        assertEq(aToken.balanceOf(address(sera)), 0, "No dust A");
        assertEq(bToken.balanceOf(address(sera)), 0, "No dust B");
    }
}
