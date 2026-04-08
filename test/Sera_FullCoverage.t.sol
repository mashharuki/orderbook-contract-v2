// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "./TestHelper.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraSOR.sol";
import "../src/mock/MockStableCoin.sol";

/**
 * @title Sera_FullCoverage
 * @notice Gap-fill tests targeting every untested branch across Sera, Vault, SeraAdmin, and SeraSOR.
 *         Goal: 100% line + branch coverage of production contracts.
 */
contract Sera_FullCoverage is TestHelper {
    Sera sera;
    SeraBatcher batcher;
    SeraSOR sor;
    Vault v;

    MockStableCoin usdt;
    MockStableCoin sgd;

    address owner;
    uint256 ownerPK;
    address executor;
    uint256 executorPK;
    address user1;
    uint256 user1PK;
    address user2;
    uint256 user2PK;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        (executor, executorPK) = makeAddrAndKey("executor");
        (user1, user1PK) = makeAddrAndKey("user1");
        (user2, user2PK) = makeAddrAndKey("user2");

        sera = _deploySera(owner);
        v = sera.vault();

        sor = new SeraSOR(address(sera));
        batcher = new SeraBatcher(address(sera), address(sor));

        vm.startPrank(owner);
        usdt = new MockStableCoin("USDT");
        sgd = new MockStableCoin("SGD");

        _whitelistToken(sera, address(usdt), true, 1);
        _whitelistToken(sera, address(sgd), true, 1);

        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.PAUSER_ROLE(), owner);
        sera.setTrustedRouter(address(sor));
        sera.setTreasury(owner);
        vm.stopPrank();
    }

    // =========================================================================
    // depositFundWithPermit: EIP-2098 compact (64-byte) signature
    // =========================================================================
    function test_depositFundWithPermit_CompactSig() public {
        uint256 permitAmount = 100 ether;
        uint256 depositAmount = 50 ether;
        usdt.mint(user1, permitAmount);

        uint256 deadline = block.timestamp + 1 hours;

        // Build a standard 65-byte permit sig, then convert to compact (64 bytes)
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 DOMAIN_SEP = usdt.DOMAIN_SEPARATOR();
        uint256 nonce = usdt.nonces(user1);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, user1, address(v), permitAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEP, structHash));

        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(user1PK, digest);

        // Convert to EIP-2098 compact format: (r, vs) where vs = (v_parity << 255) | s
        uint256 vParity = vv == 28 ? 1 : 0;
        bytes32 vs = bytes32((vParity << 255) | uint256(s));
        bytes memory compactSig = abi.encodePacked(r, vs);

        assertEq(compactSig.length, 64, "Compact sig must be 64 bytes");

        sera.depositFundWithPermit(address(usdt), user1, permitAmount, depositAmount, deadline, compactSig);

        assertEq(v.balanceOf(address(usdt), user1), depositAmount, "Deposited via compact sig");
        assertEq(usdt.balanceOf(user1), permitAmount - depositAmount, "Remaining in wallet");
    }

    // =========================================================================
    // depositFundWithPermit: revert on bad sig length
    // =========================================================================
    function test_depositFundWithPermit_BadSigLength_Reverts() public {
        usdt.mint(user1, 100 ether);
        vm.prank(user1);
        usdt.approve(address(v), 0); // ensure no pre-existing allowance

        // 63 bytes — invalid
        bytes memory badSig = new bytes(63);
        vm.expectRevert(Sera.InvalidSignatureLength.selector);
        sera.depositFundWithPermit(address(usdt), user1, 100 ether, 50 ether, block.timestamp + 1, badSig);
    }

    // =========================================================================
    // depositFundWithPermit: revert depositAmount > permitAmount
    // =========================================================================
    function test_depositFundWithPermit_DepositExceedsPermit_Reverts() public {
        usdt.mint(user1, 100 ether);
        bytes memory sig = new bytes(65);

        vm.expectRevert(Sera.AmountMismatch.selector);
        sera.depositFundWithPermit(address(usdt), user1, 50 ether, 100 ether, block.timestamp + 1, sig);
    }

    // =========================================================================
    // depositFundWithPermit: revert on non-whitelisted token
    // =========================================================================
    function test_depositFundWithPermit_NotWhitelisted_Reverts() public {
        MockStableCoin jpy = new MockStableCoin("JPY");
        jpy.mint(user1, 100 ether);
        bytes memory sig = new bytes(65);

        vm.expectRevert(abi.encodeWithSelector(SeraAdmin.TokenNotWhitelisted.selector, address(jpy)));
        sera.depositFundWithPermit(address(jpy), user1, 100 ether, 50 ether, block.timestamp + 1, sig);
    }

    // =========================================================================
    // depositFundWithPermit: skip permit when allowance already sufficient
    // =========================================================================
    function test_depositFundWithPermit_SkipPermit_WhenAllowanceSufficient() public {
        usdt.mint(user1, 100 ether);
        vm.prank(user1);
        usdt.approve(address(v), 100 ether);

        // Pass garbage sig — it should never be used because allowance is sufficient
        bytes memory garbageSig = new bytes(65);
        sera.depositFundWithPermit(address(usdt), user1, 100 ether, 50 ether, block.timestamp + 1, garbageSig);

        assertEq(v.balanceOf(address(usdt), user1), 50 ether);
    }

    // =========================================================================
    // depositFund: revert when caller != owner
    // =========================================================================
    function test_depositFund_UnauthorizedCaller_Reverts() public {
        usdt.mint(user1, 100 ether);
        vm.prank(user1);
        usdt.approve(address(v), 100 ether);

        // user2 tries to deposit user1's funds
        vm.prank(user2);
        vm.expectRevert(Sera.UnauthorizedDepositCaller.selector);
        sera.depositFund(address(usdt), user1, 100 ether);
    }

    // =========================================================================
    // depositFund: revert on non-whitelisted token
    // =========================================================================
    function test_depositFund_NotWhitelisted_Reverts() public {
        MockStableCoin jpy = new MockStableCoin("JPY");
        jpy.mint(user1, 100 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SeraAdmin.TokenNotWhitelisted.selector, address(jpy)));
        sera.depositFund(address(jpy), user1, 100 ether);
    }

    // =========================================================================
    // emergencyWithdraw: revert on zero address token
    // =========================================================================
    function test_emergencyWithdraw_ZeroToken_Reverts() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SeraAdmin.InvalidToken.selector, address(0)));
        sera.emergencyWithdraw(address(0), 100 ether);
    }

    // =========================================================================
    // emergencyWithdraw: revert on zero amount
    // =========================================================================
    function test_emergencyWithdraw_ZeroAmount_Reverts() public {
        vm.prank(user1);
        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.emergencyWithdraw(address(usdt), 0);
    }

    // =========================================================================
    // emergencyWithdraw: revert when delay not met
    // =========================================================================
    function test_emergencyWithdraw_NotReady_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(user1);
        sera.emergencyWithdraw(address(usdt), 100 ether); // request

        vm.roll(block.number + 100); // not enough blocks

        vm.prank(user1);
        vm.expectRevert(Sera.WithdrawNotReady.selector);
        sera.emergencyWithdraw(address(usdt), 100 ether);
    }

    // =========================================================================
    // emergencyWithdraw: revert execute amount > request amount
    // =========================================================================
    function test_emergencyWithdraw_AmountMismatch_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 200 ether, sera);

        vm.prank(user1);
        sera.emergencyWithdraw(address(usdt), 100 ether); // request 100

        vm.roll(block.number + 7201);

        vm.prank(user1);
        vm.expectRevert(Sera.AmountMismatch.selector);
        sera.emergencyWithdraw(address(usdt), 150 ether); // try to withdraw 150 > 100
    }

    // =========================================================================
    // matchOrders: revert on expired deadline
    // =========================================================================
    function test_matchOrders_ExpiredDeadline_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(MatchExpired.selector);
        sera.matchOrders(m, block.timestamp - 1); // deadline in the past
    }

    // =========================================================================
    // matchOrders: revert on invalid signature (wrong signer)
    // =========================================================================
    function test_matchOrders_InvalidSignature_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        // Sign o0 with WRONG key (user2PK instead of user1PK)
        MatchData memory m = MatchData(o0, _signOrder(user2PK, o0, sera), 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on invalid signature length
    // =========================================================================
    function test_matchOrders_InvalidSigLength_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        bytes memory badSig = new bytes(63); // not 64 or 65
        MatchData memory m = MatchData(o0, badSig, 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on zero matchAmount
    // =========================================================================
    function test_matchOrders_ZeroMatchAmount_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 0, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on order with zero fromAmount (first fill validation)
    // =========================================================================
    function test_matchOrders_ZeroFromAmount_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 0, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 1, o1, _signOrder(user2PK, o1, sera), 1);

        vm.prank(executor);
        vm.expectRevert(); // InvalidAmount (fromAmount == 0) or OrderFilledAmountExceeded
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on expiration too long
    // =========================================================================
    function test_matchOrders_ExpirationTooLong_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 366 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.OrderExpirationTooLong.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on fee > 100%
    // =========================================================================
    function test_matchOrders_InvalidFee_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 100_000_000_000_001, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.InvalidFee.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert on below minimum amount
    // =========================================================================
    function test_matchOrders_BelowMinAmount_Reverts() public {
        // Set minimum to 100 ether for USDT
        vm.prank(owner);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 100 ether;
        sera.batchModifyWhitelistedTokens(tokens, true, mins);

        _mintAndDeposit(user1, address(usdt), 50 ether, sera);
        _mintAndDeposit(user2, address(sgd), 50 ether, sera);

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 50 ether, 5 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 5 ether, 50 ether, 0, 2);

        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 50 ether, o1, _signOrder(user2PK, o1, sera), 5 ether);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Sera.AmountBelowMinimum.selector, 50 ether, 100 ether));
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // matchOrders: revert when paused
    // =========================================================================
    function test_matchOrders_WhenPaused_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 100 ether, sera);

        vm.prank(owner);
        sera.pause();

        Order memory o0 = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1 = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);
        MatchData memory m = MatchData(o0, _signOrder(user1PK, o0, sera), 1000 ether, o1, _signOrder(user2PK, o1, sera), 100 ether);

        vm.prank(executor);
        vm.expectRevert(); // EnforcedPause
        sera.matchOrders(m, type(uint256).max);

        vm.prank(owner);
        sera.unpause();
    }

    // =========================================================================
    // matchOrders: revert on self-match (same order both sides)
    // =========================================================================
    function test_matchOrders_SelfMatch_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 1000 ether, sera);

        // Same-token order creates identical hashes → would trigger both SameTokenMatch and SelfMatch.
        // SameTokenMatch fires first as defense-in-depth; SelfMatch is a secondary guard.
        Order memory o = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(usdt), 1000 ether, 1000 ether, 0, 1);
        bytes memory sig = _signOrder(user1PK, o, sera);

        MatchData memory m = MatchData(o, sig, 500 ether, o, sig, 500 ether);

        vm.prank(executor);
        vm.expectRevert(Sera.SameTokenMatch.selector);
        sera.matchOrders(m, type(uint256).max);
    }

    // =========================================================================
    // executeInstantWithdrawDualSig: revert paths
    // =========================================================================
    function test_instantWithdraw_ExpiredDeadline_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp - 1, 1);
        bytes memory sig = new bytes(65);

        vm.expectRevert(Sera.IntentExpired.selector);
        sera.executeInstantWithdrawDualSig(intent, sig, sig);
    }

    function test_instantWithdraw_LengthMismatch_Reverts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdt);
        tokens[1] = address(sgd);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 1);
        bytes memory sig = new bytes(65);

        vm.expectRevert(Sera.LengthMismatch.selector);
        sera.executeInstantWithdrawDualSig(intent, sig, sig);
    }

    function test_instantWithdraw_EmptyTokens_Reverts() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 1);
        bytes memory sig = new bytes(65);

        vm.expectRevert(Sera.InvalidTokenCount.selector);
        sera.executeInstantWithdrawDualSig(intent, sig, sig);
    }

    function test_instantWithdraw_TooManyTokens_Reverts() public {
        address[] memory tokens = new address[](21);
        uint256[] memory amounts = new uint256[](21);
        for (uint256 i; i < 21; i++) {
            tokens[i] = address(usdt);
            amounts[i] = 1;
        }

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 1);
        bytes memory sig = new bytes(65);

        vm.expectRevert(Sera.InvalidTokenCount.selector);
        sera.executeInstantWithdrawDualSig(intent, sig, sig);
    }

    function test_instantWithdraw_BadExecutorSigLength_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 99);

        bytes memory userSig = _signWithdrawIntentHelper(user1PK, intent);
        bytes memory badExecSig = new bytes(63); // bad length

        vm.expectRevert(Sera.InvalidSignatureLength.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, badExecSig);
    }

    function test_instantWithdraw_BadExecutorRole_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 88);

        bytes memory userSig = _signWithdrawIntentHelper(user1PK, intent);
        // Sign with user2 who does NOT have executor role
        bytes memory badExecSig = _signWithdrawIntentHelper(user2PK, intent);

        vm.expectRevert(Sera.InvalidSignature.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, badExecSig);
    }

    function test_instantWithdraw_ZeroAmountInArray_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0; // zero amount

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 77);

        bytes memory userSig = _signWithdrawIntentHelper(user1PK, intent);
        bytes memory execSig = _signWithdrawIntentHelper(executorPK, intent);

        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.executeInstantWithdrawDualSig(intent, userSig, execSig);
    }

    function test_instantWithdraw_ZeroTokenInArray_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(0); // zero address token
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, user1, block.timestamp + 1 hours, 66);

        bytes memory userSig = _signWithdrawIntentHelper(user1PK, intent);
        bytes memory execSig = _signWithdrawIntentHelper(executorPK, intent);

        vm.expectRevert(abi.encodeWithSelector(SeraAdmin.InvalidToken.selector, address(0)));
        sera.executeInstantWithdrawDualSig(intent, userSig, execSig);
    }

    function test_instantWithdraw_ZeroRecipient_FallsBackToUser() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;

        WithdrawIntent memory intent = WithdrawIntent(user1, tokens, amounts, address(0), block.timestamp + 1 hours, 55);

        bytes memory userSig = _signWithdrawIntentHelper(user1PK, intent);
        bytes memory execSig = _signWithdrawIntentHelper(executorPK, intent);

        sera.executeInstantWithdrawDualSig(intent, userSig, execSig);

        // recipient = address(0) → fallback to intent.user
        assertEq(usdt.balanceOf(user1), 50 ether, "Withdrawn to user when recipient=0");
    }

    // =========================================================================
    // Admin: setTrustedRouter revert on zero address
    // =========================================================================
    function test_setTrustedRouter_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAddress.selector);
        sera.setTrustedRouter(address(0));
    }

    // =========================================================================
    // Admin: setTreasury revert on zero address
    // =========================================================================
    function test_setTreasury_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAddress.selector);
        sera.setTreasury(address(0));
    }

    // =========================================================================
    // Admin: batchModifyWhitelistedTokens revert on length mismatch
    // =========================================================================
    function test_batchModifyWhitelistedTokens_LengthMismatch_Reverts() public {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.batchModifyWhitelistedTokens(tokens, true, amounts);
    }

    // =========================================================================
    // Admin: batchModifyWhitelistedTokens revert on zero address token
    // =========================================================================
    function test_batchModifyWhitelistedTokens_ZeroToken_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAddress.selector);
        sera.batchModifyWhitelistedTokens(tokens, true, amounts);
    }

    // =========================================================================
    // Admin: setSlippageShares revert on zero totalBps
    // =========================================================================
    function test_setSlippageShares_ZeroTotal_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SeraAdmin.InvalidAmount.selector);
        sera.setSlippageShares(0, 0, 0, 0);
    }

    // =========================================================================
    // Vault: transferLedger tested directly
    // =========================================================================
    function test_vault_transferLedger() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        v.transferLedger(user1, user2, address(usdt), 50 ether);

        assertEq(v.balanceOf(address(usdt), user1), 50 ether);
        assertEq(v.balanceOf(address(usdt), user2), 50 ether);
    }

    // =========================================================================
    // Vault: transferLedger revert paths
    // =========================================================================
    function test_vault_transferLedger_ZeroTo_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAddress.selector);
        v.transferLedger(user1, address(0), address(usdt), 50 ether);
    }

    function test_vault_transferLedger_ZeroAmount_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAmount.selector);
        v.transferLedger(user1, user2, address(usdt), 0);
    }

    function test_vault_transferLedger_InsufficientBalance_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.InsufficientBalance.selector);
        v.transferLedger(user1, user2, address(usdt), 200 ether);
    }

    // =========================================================================
    // Vault: deposit revert for blacklisted user
    // =========================================================================
    function test_vault_deposit_Blacklisted_Reverts() public {
        usdt.mint(user1, 100 ether);
        vm.prank(user1);
        usdt.approve(address(v), 100 ether);

        vm.prank(owner);
        v.setBlacklisted(user1, true);

        vm.prank(address(sera));
        vm.expectRevert(abi.encodeWithSelector(IVault.BlacklistedUser.selector, user1));
        v.deposit(user1, address(usdt), 100 ether);
    }

    // =========================================================================
    // Vault: deposit revert for zero amount
    // =========================================================================
    function test_vault_deposit_ZeroAmount_Reverts() public {
        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAmount.selector);
        v.deposit(user1, address(usdt), 0);
    }

    // =========================================================================
    // Vault: withdraw revert paths
    // =========================================================================
    function test_vault_withdraw_ZeroTo_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAddress.selector);
        v.withdraw(user1, address(usdt), 50 ether, address(0));
    }

    function test_vault_withdraw_ZeroAmount_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAmount.selector);
        v.withdraw(user1, address(usdt), 0, user1);
    }

    function test_vault_withdraw_InsufficientBalance_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        vm.prank(address(sera));
        vm.expectRevert(IVault.InsufficientBalance.selector);
        v.withdraw(user1, address(usdt), 200 ether, user1);
    }

    // =========================================================================
    // Vault: creditLedger revert for zero address user
    // =========================================================================
    function test_vault_creditLedger_ZeroUser_Reverts() public {
        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAddress.selector);
        v.creditLedger(address(0), address(usdt), 100 ether);
    }

    // =========================================================================
    // Vault: creditLedger revert for zero amount
    // =========================================================================
    function test_vault_creditLedger_ZeroAmount_Reverts() public {
        vm.prank(address(sera));
        vm.expectRevert(IVault.ZeroAmount.selector);
        v.creditLedger(user1, address(usdt), 0);
    }

    // =========================================================================
    // Vault: rescueToken with surplus
    // =========================================================================
    function test_vault_rescueToken_RescuesSurplus() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);

        // Send extra tokens directly (not via deposit)
        usdt.mint(address(v), 25 ether);

        vm.prank(owner);
        v.rescueToken(address(usdt), owner, 25 ether);
        assertEq(usdt.balanceOf(owner), 25 ether);
    }

    function test_vault_rescueToken_CannotExceedSurplus_Reverts() public {
        _mintAndDeposit(user1, address(usdt), 100 ether, sera);
        usdt.mint(address(v), 10 ether);

        vm.prank(owner);
        vm.expectRevert(IVault.CannotRescueTrackedFunds.selector);
        v.rescueToken(address(usdt), owner, 50 ether); // 50 > 10 surplus
    }

    // =========================================================================
    // batchMatchMixed (covers the untested mixed batch function)
    // =========================================================================
    function test_batchMatchMixed() public {
        _mintAndDeposit(user1, address(usdt), 2000 ether, sera);
        _mintAndDeposit(user2, address(sgd), 200 ether, sera);

        Order memory o0a = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1);
        Order memory o1a = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2);
        Order memory o0b = Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 3);
        Order memory o1b = Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 4);

        // Atomic batch with 1 match
        MatchData[] memory atomicMatches = new MatchData[](1);
        atomicMatches[0] = MatchData(o0a, _signOrder(user1PK, o0a, sera), 1000 ether, o1a, _signOrder(user2PK, o1a, sera), 100 ether);

        SeraBatcher.AtomicBatch[] memory atomicBatches = new SeraBatcher.AtomicBatch[](1);
        atomicBatches[0] = SeraBatcher.AtomicBatch(atomicMatches);

        // Single match
        MatchData[] memory singles = new MatchData[](1);
        singles[0] = MatchData(o0b, _signOrder(user1PK, o0b, sera), 1000 ether, o1b, _signOrder(user2PK, o1b, sera), 100 ether);

        SeraBatcher.IntentExecution[] memory intents = new SeraBatcher.IntentExecution[](0);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchMixed(atomicBatches, singles, intents, type(uint256).max);
        assertEq(failedMask, 0, "No failures");

        assertEq(sgd.balanceOf(user1), 200 ether, "User1 received SGD");
        assertEq(usdt.balanceOf(user2), 2000 ether, "User2 received USDT");
    }

    // =========================================================================
    // SOR: revert paths
    // =========================================================================
    function test_sor_EmptyRoute_Reverts() public {
        MatchData[] memory matches = new MatchData[](0);
        bytes memory sig = new bytes(65);

        vm.prank(executor);
        vm.expectRevert(SeraSOR.EmptyRoute.selector);
        sor.executeIntent(matches, sig, IntentParams(user1, address(usdt), address(sgd), 0, 0, user1, 0, 1, uint48(block.timestamp + 1 days)), 3, 0, bytes(""));
    }

    function test_sor_DeadlineExpired_Reverts() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData(
            Order(user1, uint48(block.timestamp + 1 days), 0, user1, address(usdt), address(sgd), 1000 ether, 100 ether, 0, 1),
            bytes(""),
            1000 ether,
            Order(user2, uint48(block.timestamp + 1 days), 0, user2, address(sgd), address(usdt), 100 ether, 1000 ether, 0, 2),
            bytes(""),
            100 ether
        );
        bytes memory sig = new bytes(65);

        vm.prank(executor);
        vm.expectRevert(MatchExpired.selector);
        sor.executeIntent(matches, sig, IntentParams(user1, address(usdt), address(sgd), 0, 0, user1, 0, 1, uint48(block.timestamp - 1)), 3, 0, bytes(""));
    }

    // =========================================================================
    // Helper: sign withdraw intent
    // =========================================================================
    function _signWithdrawIntentHelper(uint256 pk, WithdrawIntent memory intent) internal view returns (bytes memory) {
        bytes32[] memory tokenWords = new bytes32[](intent.tokens.length);
        for (uint256 i; i < intent.tokens.length; i++) {
            tokenWords[i] = bytes32(uint256(uint160(intent.tokens[i])));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                keccak256(abi.encodePacked(tokenWords)),
                keccak256(abi.encodePacked(intent.amounts)),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );
        bytes32 domainSep = sera.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, vv);
    }
}
