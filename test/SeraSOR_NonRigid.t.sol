// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";

/**
 * @title SeraSOR_NonRigid_Test
 * @dev Comprehensive tests for the non-rigid SOR features:
 *      - Dynamic fills via type(uint256).max sentinel
 *      - maxInputAmount / minOutputAmount envelope guards
 *      - Built-in positive slippage (reduced input model)
 *      - Edge cases and attack vectors
 */
contract SeraSOR_NonRigid_Test is TestHelper {
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

    // ============ HELPERS ============


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

    // ============ 1. DYNAMIC FILL — SENTINEL ============

    /// @notice Two-leg hop where Leg 2 uses type(uint256).max sentinel to consume all Leg 1 output.
    function test_DynamicFill_TwoLegHop() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (intermediate — hold in Sera)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera); // Hold for next leg
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: ETH → BTC (final — deliver to taker)
        // fromAmount = 10 ether (max the taker commits to), but matchAmount0 = type(uint256).max (sentinel)
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        // Sentinel: consume all transient ETH from Leg 1
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker gets BTC, makers get their tokens
        assertEq(btc.balanceOf(taker), 1 ether, "Taker received BTC");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
        assertEq(eth.balanceOf(maker2), 10 ether, "Maker2 received ETH");
        assertEq(eth.balanceOf(address(sera)), 0, "No ETH stuck in Sera");
    }

    /// @notice Sentinel on first leg with no transient should revert
    function test_DynamicFill_SentinelOnFirstLeg_NoTransient_Reverts() public {
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        // Sentinel on first leg with no transient or wallet deposit
        matches[0] = MatchData(takerLeg1, bytes(""), type(uint256).max, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    /// @notice Sentinel with zero transient balance available should revert
    function test_DynamicFill_SentinelWithZeroTransient_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (delivers to taker — NOT held in Sera)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = taker; // NOT holding — delivers directly
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: BTC → ETH (sentinel on BTC which was never held in transient)
        Order memory takerLeg2 = _makeOrder(taker, address(btc), address(eth), 1 ether, 10 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(eth), address(btc), 10 ether, 1 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 2. ENVELOPE GUARDS ============

    /// @notice minOutputAmount guard blocks route when output is below threshold
    function test_MinOutputGuard_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with minOutputAmount = 11 ether (above actual 10 ether output)
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 11 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InsufficientOutput.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 11 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    /// @notice minOutputAmount guard passes when output meets threshold
    function test_MinOutputGuard_Passes() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with minOutputAmount = 10 ether (exactly meets)
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether, "Taker received ETH");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
    }

    /// @notice maxInputAmount guard blocks route when input exceeds threshold
    function test_MaxInputGuard_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with maxInputAmount = 999 ether (below actual 1000 ether input)
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 999 ether, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.ExcessiveInput.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 999 ether, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    /// @notice maxInputAmount guard passes when input meets threshold
    function test_MaxInputGuard_Passes() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with maxInputAmount = 1000 ether (exactly meets)
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether, "Taker received ETH");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
    }

    /// @notice maxInputAmount includes initialDepositAmount (wallet pull)
    function test_MaxInputGuard_IncludesInitialDeposit() public {
        // Taker has 400 USDC in vault + 600 USDC in wallet
        _mintAndDeposit(taker, address(usdc), 400 ether, sera);
        usdc.mint(taker, 600 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 600 ether);

        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerOrder.initialDepositAmount = 600 ether;
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // maxInputAmount = 999 ether, but total input = 600 (wallet) + 400 (vault) = 1000 ether
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 999 ether, 0, taker, 600 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.ExcessiveInput.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 999 ether, 0, taker, 600 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 3. BUILT-IN POSITIVE SLIPPAGE ============

    /// @notice Executor reduces matchAmount0 below fromAmount — taker pays less (positive slippage)
    function test_BuiltInPositiveSlippage_ReducedInput() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Taker order allows up to 1000 USDC for 10 ETH
        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        // Maker order: 10 ETH for 900 USDC (better rate — maker willing to accept less)
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 900 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        // Executor fills at 900 USDC (reduced from taker's max 1000)
        matches[0] = MatchData(takerOrder, bytes(""), 900 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // No minOutputAmount guard — taker gets executionValue0 = Ceil(900 * 10/1000) = 9 ETH
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker only spent 900 USDC (not 1000)
        // Taker receives: executionValue0 = Ceil(900 * 10/1000) = 9 ETH
        assertEq(eth.balanceOf(taker), 9 ether, "Taker received 9 ETH (price curve of 1000:10 applied to 900)");
        assertEq(sera.vault().balanceOf(address(usdc), taker), 100 ether, "Taker kept 100 USDC in vault");
        assertEq(usdc.balanceOf(maker1), 900 ether, "Maker received 900 USDC");
        
        // Slippage share assertions: 1 ETH spread on Token 1 side is split 50/50 between Protocol. treasury and implicitly retained by Maker
        assertEq(sera.vault().balanceOf(address(eth), maker1), 0.5 ether, "Maker1 kept 0.5 ETH spread in vault");
        assertEq(sera.vault().balanceOf(address(eth), sera.treasury()), 0.5 ether, "Treasury captured 0.5 ETH spread");
    }

    // ============ 4. DYNAMIC FILL + GUARDS COMBINED ============

    /// @notice Multi-leg with sentinel + minOutputAmount guard — end-to-end
    function test_DynamicFill_WithMinOutputGuard() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (hold)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: ETH → BTC (deliver, sentinel)
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        // Guard: taker expects at least 1 BTC out
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 1 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 1 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(btc.balanceOf(taker), 1 ether, "Taker received BTC");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
        assertEq(eth.balanceOf(maker2), 10 ether, "Maker2 received ETH");
    }

    // ============ 5. SIGNATURE SECURITY ============

    /// @notice Guard params are bound to signature — using wrong guard params reverts
    function test_GuardParams_BoundToSignature() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with maxInput=1000, minOutput=10
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // But executor tries to use different guard params (maxInput=0, minOutput=0)
        // This should fail because the signature was over (1000, 10) not (0, 0)
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    /// @notice Executor can't bypass minOutputAmount by passing a lower value
    function test_Executor_CannotLowerGuard() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        // Sign with minOutput=10 ether
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Executor tries to pass minOutputAmount=5 ether (lower) — signature mismatch
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 5 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 6. FILLED AMOUNT CORRECTNESS ============

    /// @notice filledAmount tracks effectiveAmount, not sentinel
    function test_FilledAmount_TracksDynamic() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Check that filledAmount for the sentinel leg recorded 10 ether (not type(uint256).max)
        bytes32 takerLeg2Hash = _getOrderHashMemory(matches[1].order0);
        assertEq(sera.filledAmount(takerLeg2Hash), 10 ether, "FilledAmount should track effective amount (10), not sentinel");
    }

    // ============ 7. EVENT EMISSION ============

    /// @notice OrderMatched event emits effectiveAmount, not sentinel
    function test_OrderMatchedEvent_EmitsEffectiveAmount() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // OrderMatched event: 3 indexed (orderHash0, user0, orderHash1)
        // 7 non-indexed: (token0, amount0, protocolTake0, user1, token1, amount1, protocolTake1)
        vm.prank(executor);
        vm.recordLogs();
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 orderMatchedSig = keccak256("OrderMatched(bytes32,address,address,uint256,uint256,bytes32,address,address,uint256,uint256)");
        uint256 orderMatchedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == orderMatchedSig) {
                orderMatchedCount++;
                if (orderMatchedCount == 2) {
                    // Decode 7 non-indexed fields:
                    // (address token0, uint256 amount0, uint256 protocolTake0, address user1, address token1, uint256 amount1, uint256 protocolTake1)
                    (, uint256 matchAmt0,,,,,) = abi.decode(
                        logs[i].data,
                        (address, uint256, uint256, address, address, uint256, uint256)
                    );
                    assertEq(matchAmt0, 10 ether, "Event should emit effective amount (10 ETH), not sentinel");
                    break;
                }
            }
        }
        assertTrue(orderMatchedCount >= 2, "Should have at least 2 OrderMatched events");
    }

    // ============ 8. BOTH GUARDS TOGETHER ============

    /// @notice Both guards can be active simultaneously
    function test_BothGuards_Pass() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        Order memory makerOrder = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 10 ether, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether, "Taker received ETH");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
    }

    // ============ 9. DYNAMIC FILL WITH POSITIVE SLIPPAGE ============

    /// @notice Sentinel + reduced input on Leg 1 — full end-to-end
    function test_DynamicFill_WithBuiltInPositiveSlippage() public {
        // Taker has 1000 USDC
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (hold) — executor fills only 900 USDC (positive slippage)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        // Maker offers better rate: 10 ETH for just 900 USDC
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 900 ether, 2);

        // Leg 2: ETH → BTC (deliver, sentinel — consume all ETH from Leg 1)
        // takerReceives from Leg 1 = executionValue0 = Ceil(900 * 10/1000) = 9 ETH
        // So sentinel resolves to 9 ETH. Maker2: 1 BTC for 9 ETH.
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 9 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        // Leg 1: fill at 900 USDC (reduced from taker's 1000 max)
        matches[0] = MatchData(takerLeg1, bytes(""), 900 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        // Leg 2: sentinel consumes all 9 ETH transient
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker spent only 900 USDC (positive slippage), got BTC
        // executionValue0 for Leg 2 = Ceil(9 * 1/10) = 0.9 BTC (taker's price curve is 10:1)
        assertEq(btc.balanceOf(taker), 0.9 ether, "Taker received 0.9 BTC (9 ETH at 10:1 rate)");
        assertEq(sera.vault().balanceOf(address(usdc), taker), 100 ether, "Taker kept 100 USDC in vault (positive slippage)");
        assertEq(usdc.balanceOf(maker1), 900 ether, "Maker1 received 900 USDC");
        assertEq(eth.balanceOf(maker2), 9 ether, "Maker2 received 9 ETH");
        
        // Slippage share assertions
        assertEq(sera.vault().balanceOf(address(eth), maker1), 0.5 ether, "Maker1 kept 0.5 ETH spread in vault");
        assertEq(sera.vault().balanceOf(address(btc), maker2), 0.05 ether, "Maker2 kept 0.05 BTC spread in vault");
        // Treasury gets 0.5 ETH from Leg 1, and 0.05 BTC from Leg 2
        assertEq(sera.vault().balanceOf(address(eth), sera.treasury()), 0.5 ether, "Treasury captured 0.5 ETH spread");
        assertEq(sera.vault().balanceOf(address(btc), sera.treasury()), 0.05 ether, "Treasury captured 0.05 BTC spread");
    }

    // ============ 10. WALLET-FUNDED DYNAMIC FILL ============

    /// @notice Wallet-funded route with sentinel on second leg
    function test_WalletFunded_DynamicFill() public {
        // Taker funds entirely from wallet
        usdc.mint(taker, 1000 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (hold, wallet-funded)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.initialDepositAmount = 1000 ether;
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: ETH → BTC (deliver, sentinel)
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 10 ether, 1 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 1 ether, 10 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 1 ether);
        // maxInputAmount = 1000 ether (includes the wallet deposit)
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 1 ether, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 1000 ether, 1 ether, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(btc.balanceOf(taker), 1 ether, "Taker received BTC");
        assertEq(usdc.balanceOf(taker), 0, "Taker wallet drained");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker1 received USDC");
        assertEq(eth.balanceOf(maker2), 10 ether, "Maker2 received ETH");
    }

    // ============ 11. PARTIAL DYNAMIC FILL — NOT ALL TRANSIENT CONSUMED ============

    /// @notice Non-input-token vault pulls are now blocked — intermediate legs must be fully covered by transient
    function test_PartialTransientConsumption_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(taker, address(eth), 5 ether, sera); // Taker also has ETH in vault for 2nd leg shortfall
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 2 ether, sera);

        // Leg 1: USDC → ETH (hold 10 ETH)
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);

        // Leg 2: wants 15 ETH total for 2 BTC — 10 from transient, 5 from vault
        // This now REVERTS because ETH is not the route's primary input token (USDC is)
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 15 ether, 2 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 2 ether, 15 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        matches[1] = MatchData(takerLeg2, bytes(""), 15 ether, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 2 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ 12. DYNAMIC FILL WITH FEES ============

    /// @notice Two-leg sentinel with fees correctly calculated on effective amount
    function test_DynamicFill_FeesCalculatedOnEffectiveAmount() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC → ETH (hold), taker fee 10%
        Order memory takerLeg1 = _makeOrder(taker, address(usdc), address(eth), 1000 ether, 10 ether, 1);
        takerLeg1.recipient = address(sera);
        takerLeg1.feeBps = 10_000_000_000_000; // 10%
        Order memory makerLeg1 = _makeOrder(maker1, address(eth), address(usdc), 10 ether, 1000 ether, 2);
        makerLeg1.feeBps = 10_000_000_000_000; // 10%

        // Leg 2: ETH → BTC (deliver, sentinel)
        // The actual ETH received after fees in Leg 1 = 10 ETH base - taker fee (10% of 10 = 1) = 9 ETH
        // But wait — fees come from execution value, not from the transient.
        // takerReceives = calc.executionValue0 - calc.protocolFee1
        // executionValue0 = Ceil(1000 * 10/1000) = 10 ETH
        // protocolFee1 = 10 ETH * 10% = 1 ETH
        // takerReceives = 10 - 1 = 9 ETH held in transient
        Order memory takerLeg2 = _makeOrder(taker, address(eth), address(btc), 9 ether, 0.9 ether, 3);
        Order memory makerLeg2 = _makeOrder(maker2, address(btc), address(eth), 0.9 ether, 9 ether, 4);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(takerLeg1, bytes(""), 1000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 10 ether);
        // Sentinel consumes the 9 ETH from transient
        matches[1] = MatchData(takerLeg2, bytes(""), type(uint256).max, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 0.9 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker receives BTC
        assertEq(btc.balanceOf(taker), 0.9 ether, "Taker received 0.9 BTC");
        assertEq(usdc.balanceOf(maker1), 900 ether, "Maker1 received 900 USDC after 10% fee");
        assertEq(eth.balanceOf(maker2), 9 ether, "Maker2 received 9 ETH");
        // Fee collected on Leg 1
        assertEq(sera.vault().balanceOf(address(eth), owner), 1 ether, "Protocol treasury got 1 ETH fee from Leg 1 Taker");
        assertEq(sera.vault().balanceOf(address(usdc), owner), 100 ether, "Protocol treasury got 100 USDC fee from Leg 1 Maker");
        // No leftover ETH in Sera
        assertEq(eth.balanceOf(address(sera)), 0, "No ETH stuck in Sera");
    }
}
