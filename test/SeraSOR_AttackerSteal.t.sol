// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Sera.sol";
import "../src/SeraSOR.sol";
import "../src/Vault.sol";
import "../src/mock/MockStableCoin.sol";
import "./TestHelper.sol";
import {Order, MatchData, SeraLib} from "../src/SeraLib.sol";

contract SeraSOR_AttackerStealTest is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    Vault public vault;
    MockStableCoin public usdc;
    MockStableCoin public eth;

    address public owner;
    address public executor;
    address public taker;
    uint256 public takerPK;
    address public maker1;
    uint256 public maker1PK;
    address public attacker;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        (taker, takerPK) = makeAddrAndKey("taker");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        attacker = makeAddr("attacker");

        usdc = new MockStableCoin("USDC");
        eth = new MockStableCoin("ETH");

        sera = _deploySera(owner);
        vault = sera.vault();
        sor = new SeraSOR(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdc), true, 1);
        _whitelistToken(sera, address(eth), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();
    }

    /// @notice Verify that the executor CANNOT redirect output to attacker.
    /// The taker signs recipient=address(0) (vault credit). The executor sets
    /// matches[0].order0.recipient = attacker. The contract must revert.
    function test_ExecutorCannotRedirectTerminalRecipient_RevertsInvalidRoute() public {
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
            recipient: attacker,
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

        uint256 nonce = 77;
        bytes memory intentSig = _signIntent(
            takerPK,
            address(usdc),
            address(eth),
            1000 ether,
            0,
            address(0),
            0,
            nonce,
            uint48(block.timestamp + 1 days),
            sera
        );

        IntentParams memory intent = IntentParams({
            inputToken: address(usdc),
            outputToken: address(eth),
            maxInputAmount: 1000 ether,
            minOutputAmount: 0,
            recipient: address(0),
            initialDepositAmount: 0,
            uuid: nonce,
            deadline: uint48(block.timestamp + 1 days)
        });

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, intentSig, intent, 2, 0, bytes(""));
    }

    /// @notice Regression test: single-leg route with recipient=address(sera) must revert.
    /// Without the fix, the executor could hold the output inside Sera on the only leg,
    /// stranding the taker's output tokens. Admin could then sweep via rescueToken.
    function test_SingleLeg_HoldOutput_RevertsInvalidRoute() public {
        // Setup: taker has USDC in vault, maker has ETH in vault
        _mintAndDeposit(taker, address(usdc), 1000 ether, sera);
        _mintAndDeposit(maker1, address(eth), 10 ether, sera);

        // Taker order — attacker sets recipient to address(sera) to hold output
        Order memory takerOrder = Order({
            user: taker,
            fromToken: address(usdc),
            toToken: address(eth),
            fromAmount: 1000 ether,
            toAmount: 10 ether,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(sera), // ATTACK: hold output in Sera
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

        // Intent: taker signs recipient=taker (the REAL destination)
        // But the executor forged the leg's recipient to address(sera)
        bytes memory intentSig = _signIntent(
            takerPK,
            address(usdc), address(eth),
            1000 ether, 0,
            taker, 0,       // signed recipient = taker
            block.timestamp, uint48(block.timestamp + 1 days),
            sera
        );

        IntentParams memory intent = IntentParams({
            inputToken: address(usdc),
            outputToken: address(eth),
            maxInputAmount: 1000 ether,
            minOutputAmount: 0,
            recipient: taker,
            initialDepositAmount: 0,
            uuid: block.timestamp,
            deadline: uint48(block.timestamp + 1 days)
        });

        vm.prank(executor);
        vm.expectRevert(SeraSOR.InvalidRoute.selector);
        sor.executeIntent(matches, intentSig, intent, 2, 0, bytes(""));
    }
}
