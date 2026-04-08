// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

/**
 * @title SeraRouteTest
 * @dev Tests for the SeraSOR (Smart Order Router) functionality:
 *      - Intent-based single-signature authorization
 *      - Single-signature authorization
 *      - Transient balance optimization for multi-hop routes
 *      - Split + multi-leg routing
 *      - Fee/spread capture on routed matches
 *      - Error cases (subset submission, wrong taker, bad signature, etc.)
 */
import "./TestHelper.sol";

contract SeraRouteTest is TestHelper {
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
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();
    }


    // ============ BASIC TESTS ============

    /// @notice Basic single-leg route succeeds with single signature
    function test_matchOrdersRouted_SingleLeg() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1
        });

        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 2
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(maker1PK, makerOrder, sera),
            matchAmount1: 10 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether);
        assertEq(usdc.balanceOf(maker1), 1000 ether);
    }

    /// @notice Testing Mixed Funds support: SOR pulls a subset of required funds from the ERC20 Wallet, and the remainder natively from the Vault.
    function test_executeRoute_MixedFunds() public {
        // Taker needs to spend 1000 USDC total.
        // Taker has exactly 400 USDC resting in the Vault...
        _mintAndDeposit(taker, address(usdc), 400 ether, sera);

        // ...and 600 USDC in their external ERC20 Wallet
        usdc.mint(taker, 600 ether);
        vm.prank(taker);
        usdc.approve(address(sor), 600 ether);

        // Maker sits on the book with 10 ETH
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 600 ether,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1
        });

        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 2
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(maker1PK, makerOrder, sera),
            matchAmount1: 10 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 600 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);

        // Execute Route pulling EXACTLY 600 USDC from the external wallet.
        // The SOR calculates a 400 USDC shortfall to execute the 1000 USDC match, which it then delegates to the Sera.sol and Vault.sol ledgers to cover.
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 600 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Verification balances
        assertEq(eth.balanceOf(taker), 10 ether, "Taker successfully bought 10 ETH");
        assertEq(usdc.balanceOf(maker1), 1000 ether, "Maker successfully received 1000 USDC");

        // Verification that Mixed Funding worked perfectly:
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Vault was completely drained of its 400 USDC");
        assertEq(usdc.balanceOf(taker), 0, "External Wallet was completely drained of its 600 USDC");
    }
    /// @notice Swap via SOR without vault logic (approves SOR)

    function test_swapRouted_SingleLeg() public {
        usdc.mint(taker, 1000 ether); // Mint directly to user wallet
        _mintAndDeposit(maker1, address(eth), 10 ether, sera); // Maker uses vault

        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether); // Taker approves SeraSOR

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 1000 ether,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 3
        });

        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 4
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(maker1PK, makerOrder, sera),
            matchAmount1: 10 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether);
        assertEq(usdc.balanceOf(maker1), 1000 ether);
    }

    /// @notice Two-leg hop (USDC→ETH→BTC) with transient balance optimization
    function test_matchOrdersRouted_TwoLegHop() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(btc), 1 ether, sera);

        // Leg 1: USDC→ETH (intermediate, hold in Sera)
        Order memory takerLeg1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days),
            uuid: 3
        });
        Order memory makerLeg1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 4
        });

        // Leg 2: ETH→BTC (final, pay out to taker)
        Order memory takerLeg2 = Order({
            user: taker,
            fromToken: address(eth),
            toToken: address(btc),
            fromAmount: 10 ether,
            toAmount: 1 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 5
        });
        Order memory makerLeg2 = Order({
            user: maker2,
            fromToken: address(btc),
            toToken: address(eth),
            fromAmount: 1 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 6
        });

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData({
            order0: takerLeg1,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerLeg1,
            signature1: _signOrder(maker1PK, makerLeg1, sera),
            matchAmount1: 10 ether
        });
        matches[1] = MatchData({
            order0: takerLeg2,
            signature0: bytes(""),
            matchAmount0: 10 ether,
            order1: makerLeg2,
            signature1: _signOrder(maker2PK, makerLeg2, sera),
            matchAmount1: 1 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(btc.balanceOf(taker), 1 ether);
        assertEq(usdc.balanceOf(maker1), 1000 ether);
        assertEq(eth.balanceOf(maker2), 10 ether);
        assertEq(eth.balanceOf(address(sera)), 0);
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0);
    }

    /// @notice Fees and spread captured correctly on routed matches
    function test_matchOrdersRouted_WithFees() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 10_000_000_000_000,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 7
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 10_000_000_000_000,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 8
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 500 ether,
            order1: makerOrder,
            signature1: _signOrder(maker1PK, makerOrder, sera),
            matchAmount1: 5 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 4.5 ether);
        assertEq(usdc.balanceOf(maker1), 450 ether);
        assertEq(sera.vault().balanceOf(address(usdc), owner), 50 ether);
        assertEq(sera.vault().balanceOf(address(eth), owner), 0.5 ether);
    }

    /// @notice Taker executes 3 legs, but only the FINAL leg defines a fee. Intermediate legs pass 100% through.
    function test_matchOrdersRouted_ComplexMultilegWithFees() public {
        _mintAndDeposit(taker, address(usdc), 5000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 2 ether, sera);
        _mintAndDeposit(maker2, address(btc), 3 ether, sera);
        _mintAndDeposit(maker3, address(eth), 5 ether, sera); // Final Output

        // Leg 1: Taker 2000 USDC -> Maker 1 for 2 ETH
        // Taker defines 0% fee on this intermediate hop
        Order memory takerLeg1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 2000 ether,
            toAmount: 2 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker, // Delivering the ETH split-end directly to the taker
            expiration: uint48(block.timestamp + 1 days),
            uuid: 70
        });
        Order memory makerLeg1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 2 ether,
            toAmount: 2000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 71
        });

        // Leg 2: Taker 3000 USDC -> Maker 2 for 3 BTC
        // Taker defines 0% fee on this intermediate hop
        Order memory takerLeg2 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(btc),
            fromAmount: 3000 ether,
            toAmount: 3 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days),
            uuid: 72
        });
        Order memory makerLeg2 = Order({
            user: maker2,
            fromToken: address(btc),
            toToken: address(usdc),
            fromAmount: 3 ether,
            toAmount: 3000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 73
        });

        // Leg 3: The 3 BTC output from Leg 2 -> Maker 3 for 5 ETH.
        // Taker defines 10% fee on THIS final hop output
        Order memory takerLeg3 = Order({
            user: taker,
            fromToken: address(btc),
            toToken: address(eth),
            fromAmount: 3 ether,
            toAmount: 5 ether,
            initialDepositAmount: 0,
            feeBps: 10_000_000_000_000, // 10% !!
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 74
        });
        Order memory makerLeg3 = Order({
            user: maker3,
            fromToken: address(eth),
            toToken: address(btc),
            fromAmount: 5 ether,
            toAmount: 3 ether,
            initialDepositAmount: 0,
            feeBps: 10_000_000_000_000, // 10%
            recipient: maker3,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 75
        });

        MatchData[] memory matches = new MatchData[](3);
        matches[0] =
            MatchData(takerLeg1, bytes(""), 2000 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 2 ether);
        matches[1] =
            MatchData(takerLeg2, bytes(""), 3000 ether, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 3 ether);
        matches[2] = MatchData(takerLeg3, bytes(""), 3 ether, makerLeg3, _signOrder(maker3PK, makerLeg3, sera), 5 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // Let's set the router in motion
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Verification
        // Taker inputs: 2000 USDC + 3000 USDC
        assertEq(usdc.balanceOf(maker1), 2000 ether, "Maker 1 gets full 2000 USDC");
        assertEq(usdc.balanceOf(maker2), 3000 ether, "Maker 2 gets full 3000 USDC");

        // Intermediate BTC Hop
        // Leg 2 produced 3 BTC (0% fee). Leg 3 accepted 3 BTC.
        // Then Maker 3 pays a 10% fee on their received 3 BTC = 0.3 BTC fee.
        assertEq(btc.balanceOf(maker3), 2.7 ether, "Maker 3 pays 10% on BTC receipt");
        assertEq(sera.vault().balanceOf(address(btc), owner), 0.3 ether, "Treasury gets 0.3 BTC from Maker 3");

        // Leg 1 produced 2 ETH directly out (0% fee).
        // Leg 3 produced 5 ETH out (10% fee on Leg 3 output = -0.5 ETH).
        // Taker TOTAL = 2 ETH (from Leg 1) + 4.5 ETH (from Leg 3) = 6.5 ETH.
        assertEq(eth.balanceOf(taker), 6.5 ether, "Taker pays fee ONLY on Leg 3 outcome");

        // Treasury Taker fee = 10% of 5 ETH = 0.5 ETH
        assertEq(sera.vault().balanceOf(address(eth), owner), 0.5 ether, "Treasury accumulates pure output token tax");

        // Final sanity check: no intermediate tax leakage
        assertEq(sera.vault().balanceOf(address(usdc), owner), 0); // Treasury didn't collect any USDC dust!
    }

    // ============ SPLIT + MULTILEG TEST ============

    /**
     * @notice Split + multi-leg routing test
     * Route: taker wants ETH. Has 1000 USDC.
     * Leg 1: 100 USDC → 1 ETH  (direct swap, final output)
     * Leg 2: 900 USDC → 0.9 BTC (intermediate hop, hold in Sera)
     * Leg 3: 0.9 BTC → 9 ETH   (final hop, pay out to taker)
     * Result: taker pays 1000 USDC, receives 10 ETH total
     */
    function test_matchOrdersRouted_SplitAndMultileg() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 1 ether, sera); // For leg 1 (direct)
        _mintAndDeposit(maker2, address(btc), 0.9 ether, sera); // For leg 2 (USDC→BTC)
        _mintAndDeposit(maker3, address(eth), 9 ether, sera); // For leg 3 (BTC→ETH)

        // Leg 1: 100 USDC → 1 ETH (direct, final output)

        // Leg 1: 100 USDC → 1 ETH (direct, final output)
        Order memory takerLeg1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 100 ether,
            toAmount: 1 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 9
        });
        Order memory makerLeg1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 1 ether,
            toAmount: 100 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 10
        });

        // Leg 2: 900 USDC → 0.9 BTC (intermediate, hold in Sera)
        Order memory takerLeg2 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(btc),
            fromAmount: 900 ether,
            toAmount: 0.9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days),
            uuid: 11
        });
        Order memory makerLeg2 = Order({
            user: maker2,
            fromToken: address(btc),
            toToken: address(usdc),
            fromAmount: 0.9 ether,
            toAmount: 900 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 12
        });

        // Leg 3: 0.9 BTC → 9 ETH (final, pay out to taker)
        Order memory takerLeg3 = Order({
            user: taker,
            fromToken: address(btc),
            toToken: address(eth),
            fromAmount: 0.9 ether,
            toAmount: 9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 13
        });
        Order memory makerLeg3 = Order({
            user: maker3,
            fromToken: address(eth),
            toToken: address(btc),
            fromAmount: 9 ether,
            toAmount: 0.9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker3,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 14
        });

        MatchData[] memory matches = new MatchData[](3);
        matches[0] = MatchData({
            order0: takerLeg1,
            signature0: bytes(""),
            matchAmount0: 100 ether,
            order1: makerLeg1,
            signature1: _signOrder(maker1PK, makerLeg1, sera),
            matchAmount1: 1 ether
        });
        matches[1] = MatchData({
            order0: takerLeg2,
            signature0: bytes(""),
            matchAmount0: 900 ether,
            order1: makerLeg2,
            signature1: _signOrder(maker2PK, makerLeg2, sera),
            matchAmount1: 0.9 ether
        });
        matches[2] = MatchData({
            order0: takerLeg3,
            signature0: bytes(""),
            matchAmount0: 0.9 ether,
            order1: makerLeg3,
            signature1: _signOrder(maker3PK, makerLeg3, sera),
            matchAmount1: 9 ether
        });
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        assertEq(eth.balanceOf(taker), 10 ether);
        assertEq(usdc.balanceOf(maker1), 100 ether);
        assertEq(usdc.balanceOf(maker2), 900 ether);
        assertEq(btc.balanceOf(maker3), 0.9 ether);

        assertEq(btc.balanceOf(address(sera)), 0);
        assertEq(eth.balanceOf(address(sera)), 0);

        assertEq(sera.vault().balanceOf(address(usdc), taker), 0);
    }

    /// @notice Split+multileg with an expired maker order in leg 3 reverts all legs atomically
    function test_matchOrdersRouted_SplitMultileg_MakerExpiredReverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 1 ether, sera);
        _mintAndDeposit(maker2, address(btc), 0.9 ether, sera);
        _mintAndDeposit(maker3, address(eth), 9 ether, sera);

        Order memory takerLeg1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 100 ether,
            toAmount: 1 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 15
        });
        Order memory makerLeg1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 1 ether,
            toAmount: 100 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 16
        });
        Order memory takerLeg2 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(btc),
            fromAmount: 900 ether,
            toAmount: 0.9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera),
            expiration: uint48(block.timestamp + 1 days),
            uuid: 17
        });
        Order memory makerLeg2 = Order({
            user: maker2,
            fromToken: address(btc),
            toToken: address(usdc),
            fromAmount: 0.9 ether,
            toAmount: 900 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 18
        });
        Order memory takerLeg3 = Order({
            user: taker,
            fromToken: address(btc),
            toToken: address(eth),
            fromAmount: 0.9 ether,
            toAmount: 9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 19
        });
        // EXPIRED maker order on leg 3
        Order memory makerLeg3 = Order({
            user: maker3,
            fromToken: address(eth),
            toToken: address(btc),
            fromAmount: 9 ether,
            toAmount: 0.9 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker3,
            expiration: uint48(block.timestamp - 1), // EXPIRED!
            uuid: 34
        });

        MatchData[] memory matches = new MatchData[](3);
        matches[0] =
            MatchData(takerLeg1, bytes(""), 100 ether, makerLeg1, _signOrder(maker1PK, makerLeg1, sera), 1 ether);
        matches[1] =
            MatchData(takerLeg2, bytes(""), 900 ether, makerLeg2, _signOrder(maker2PK, makerLeg2, sera), 0.9 ether);
        matches[2] =
            MatchData(takerLeg3, bytes(""), 0.9 ether, makerLeg3, _signOrder(maker3PK, makerLeg3, sera), 9 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        vm.expectRevert(Sera.OrderExpired.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // All legs reverted — no state changed
        assertEq(sera.vault().balanceOf(address(usdc), taker), 1000 ether, "Taker vault unchanged");
        assertEq(sera.vault().balanceOf(address(eth), maker1), 1 ether, "Maker1 vault unchanged");
    }

    // ============ ERROR CASES ============

    /// @notice Same intent cannot be executed twice (replay protection)
    function test_executeIntent_RejectsReplay() public {
        _mintAndDeposit(taker, address(usdc), 2000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 20 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 20
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 21
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);

        bytes memory sorSig = _signIntent(takerPK, address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        // First execution succeeds
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Prepare second execution with different maker/uuid but same intent
        Order memory makerOrder2 = makerOrder;
        makerOrder2.uuid = 22;
        matches[0] = MatchData(takerOrder, bytes(""), 1000 ether, makerOrder2, _signOrder(maker1PK, makerOrder2, sera), 10 ether);

        // Second execution with same intent signature reverts
        vm.prank(executor);
        vm.expectRevert(SeraSOR.IntentAlreadyUsed.selector);
        sor.executeIntent(matches, sorSig, IntentParams(address(usdc), address(eth), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // test_matchOrdersRouted_RejectsMakerWithRouteHash removed — routeHash field no longer exists in Order struct.

    /// @notice Different taker users across legs is rejected
    function test_matchOrdersRouted_RejectsDifferentTakers() public {
        _mintAndDeposit(taker, address(usdc), 500 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);
        _mintAndDeposit(maker2, address(eth), 10 ether, sera);

        Order memory takerOrder1 = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 500 ether,
            toAmount: 5 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 24
        });
        Order memory takerOrder2 = Order({
            user: maker1, // WRONG — different taker
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 500 ether,
            toAmount: 5 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 25
        });
        Order memory makerOrder1 = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 5 ether,
            toAmount: 500 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 26
        });
        Order memory makerOrder2 = Order({
            user: maker2,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 5 ether,
            toAmount: 500 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 27
        });

        MatchData[] memory matches = new MatchData[](2);
        matches[0] =
            MatchData(takerOrder1, bytes(""), 500 ether, makerOrder1, _signOrder(maker1PK, makerOrder1, sera), 5 ether);
        matches[1] =
            MatchData(takerOrder2, bytes(""), 500 ether, makerOrder2, _signOrder(maker2PK, makerOrder2, sera), 5 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // test_matchOrders_RejectsRouteBoundOrder removed — routeHash field and OrderRequiresRoute error no longer exist.

    /// @notice Routed execution fails if SeraSOR is not the trustedRouter in Sera
    function test_matchOrdersRouted_RevertsWithoutTrustedRouter() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 30
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 31
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);

        vm.prank(owner);
        sera.setTrustedRouter(address(0x123)); // Set to dummy router

        vm.prank(executor);
        vm.expectRevert(Sera.RouterNotTrusted.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    /// @notice Bad route signature reverts
    function test_matchOrdersRouted_InvalidSignature() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 32
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 33
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);

        // Sign with maker1's key instead of taker's
        bytes memory sorSig = _signIntent(maker1PK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));
    }

    // ============ Fund Source / Destination Matrix Tests ============

    /// @notice Vault-pull → Wallet-return (recipient = taker address)
    function test_executeRoute_VaultPull_WalletReturn() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker, // Return to wallet
            expiration: uint48(block.timestamp + 1 days),
            uuid: 100
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 101
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker received ETH directly in wallet
        assertEq(eth.balanceOf(taker), 10 ether, "Taker should receive ETH in wallet");
        assertEq(sera.vault().balanceOf(address(eth), taker), 0, "Taker vault ETH should be 0");
        // Taker USDC was pulled from vault
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Taker vault USDC should be spent");
    }

    /// @notice Vault-pull → Vault-return (recipient = address(0))
    function test_executeRoute_VaultPull_VaultReturn() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0), // Return to vault ledger
            expiration: uint48(block.timestamp + 1 days),
            uuid: 200
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 201
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, address(0), 0, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, address(0), 0, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker received ETH inside vault ledger
        assertEq(eth.balanceOf(taker), 0, "Taker wallet ETH should be 0");
        assertEq(sera.vault().balanceOf(address(eth), taker), 10 ether, "Taker should receive ETH in vault");
    }

    /// @notice Wallet-pull → Wallet-return (initialDepositAmount > 0, recipient = taker)
    function test_executeRoute_WalletPull_WalletReturn() public {
        usdc.mint(taker, 1000 ether); // Mint directly to wallet
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 1000 ether,
            feeBps: 0,
            recipient: taker, // Return to wallet
            expiration: uint48(block.timestamp + 1 days),
            uuid: 300
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 301
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, taker, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker got ETH in wallet, USDC was pulled directly from wallet
        assertEq(eth.balanceOf(taker), 10 ether, "Taker should receive ETH in wallet");
        assertEq(usdc.balanceOf(taker), 0, "Taker wallet USDC should be 0");
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Taker vault USDC should be 0");
    }

    /// @notice Wallet-pull → Vault-return (initialDepositAmount > 0, recipient = address(0))
    function test_executeRoute_WalletPull_VaultReturn() public {
        usdc.mint(taker, 1000 ether); // Mint directly to wallet
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 1000 ether,
            feeBps: 0,
            recipient: address(0), // Return to vault ledger
            expiration: uint48(block.timestamp + 1 days),
            uuid: 400
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 401
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, address(0), 1000 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, address(0), 1000 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // Taker got ETH credited to vault, USDC was pulled directly from wallet
        assertEq(eth.balanceOf(taker), 0, "Taker wallet ETH should be 0");
        assertEq(sera.vault().balanceOf(address(eth), taker), 10 ether, "Taker should receive ETH in vault");
        assertEq(usdc.balanceOf(taker), 0, "Taker wallet USDC should be 0");
        assertEq(sera.vault().balanceOf(address(usdc), taker), 0, "Taker vault USDC should be 0");
    }

    /// @notice Wallet-pull → Third-party wallet return (recipient = different address)
    function test_executeRoute_WalletPull_ThirdPartyReturn() public {
        usdc.mint(taker, 1000 ether);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        vm.prank(taker);
        usdc.approve(address(sor), 1000 ether);

        address thirdParty = makeAddr("thirdParty");

        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 1000 ether,
            feeBps: 0,
            recipient: thirdParty, // Return to a different address
            expiration: uint48(block.timestamp + 1 days),
            uuid: 500
        });
        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(eth),
            toToken: address(usdc),
            fromAmount: 10 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 501
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] =
            MatchData(takerOrder, bytes(""), 1000 ether, makerOrder, _signOrder(maker1PK, makerOrder, sera), 10 ether);
        bytes memory sorSig = _signIntent(takerPK, matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, thirdParty, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days), sera);
        vm.prank(executor);
        sor.executeIntent(matches, sorSig, IntentParams(matches[0].order0.fromToken, matches[matches.length - 1].order0.toToken, 0, 0, thirdParty, 1000 ether, block.timestamp, uint48(block.timestamp + 1 days)), uint8(matches.length * 2 + 1), 0, bytes(""));

        // ETH was sent to the third party, not the taker
        assertEq(eth.balanceOf(thirdParty), 10 ether, "Third party should receive ETH");
        assertEq(eth.balanceOf(taker), 0, "Taker wallet ETH should be 0");
        assertEq(sera.vault().balanceOf(address(eth), taker), 0, "Taker vault ETH should be 0");
    }

    // =========================================================================
    // SFO-05: settleRoutedLeg must reject same-token legs and self-matches
    // =========================================================================

    /// @notice settleRoutedLeg reverts on same-token leg (fromToken == toToken)
    function test_settleRoutedLeg_SameTokenMatch_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(usdc), 1000 ether, sera);

        // Both orders trade USDC → USDC (same token)
        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(usdc),
            fromAmount: 1000 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1
        });

        Order memory makerOrder = Order({
            user: maker1,
            fromToken: address(usdc),
            toToken: address(usdc),
            fromAmount: 1000 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 2
        });

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: takerOrder,
            signature0: bytes(""),
            matchAmount0: 1000 ether,
            order1: makerOrder,
            signature1: _signOrder(maker1PK, makerOrder, sera),
            matchAmount1: 1000 ether
        });

        bytes memory sorSig = _signIntent(
            takerPK, address(usdc), address(usdc), 0, 0, taker, 0,
            block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        vm.expectRevert(Sera.SameTokenMatch.selector);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(address(usdc), address(usdc), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            uint8(matches.length * 2 + 1), 0, bytes("")
        );
    }

    /// @notice settleRoutedLeg reverts on self-match (identical order on both sides)
    function test_settleRoutedLeg_SelfMatch_Reverts() public {
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);

        // Same-token order so TokenMismatch passes, but both SameTokenMatch and SelfMatch apply.
        // SameTokenMatch fires first.
        Order memory o = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(usdc),
            fromAmount: 1000 ether,
            toAmount: 1000 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: taker,
            expiration: uint48(block.timestamp + 1 days),
            uuid: 1
        });

        bytes memory sig = _signOrder(takerPK, o, sera);

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(o, bytes(""), 500 ether, o, sig, 500 ether);

        bytes memory sorSig = _signIntent(
            takerPK, address(usdc), address(usdc), 0, 0, taker, 0,
            block.timestamp, uint48(block.timestamp + 1 days), sera
        );

        vm.prank(executor);
        vm.expectRevert(Sera.SameTokenMatch.selector);
        sor.executeIntent(
            matches, sorSig,
            IntentParams(address(usdc), address(usdc), 0, 0, taker, 0, block.timestamp, uint48(block.timestamp + 1 days)),
            uint8(matches.length * 2 + 1), 0, bytes("")
        );
    }
}
