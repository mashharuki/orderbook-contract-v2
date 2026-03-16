// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "./TestHelper.sol";
import "../src/SeraBatcher.sol";
import "../src/SeraBase.sol";
import {ORDER_TYPEHASH, InvalidCostAmount} from "../src/SeraLib.sol";

contract SeraBatcherTest is TestHelper {
    Sera public sera;
    SeraBatcher public batcher;
    MockStableCoin public usdt;
    MockStableCoin public sgd;

    address public owner;
    uint256 public ownerPK;
    address public executor;
    address public maker1;
    uint256 public maker1PK;
    address public maker2;
    uint256 public maker2PK;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        executor = makeAddr("executor");
        (maker1, maker1PK) = makeAddrAndKey("maker1");
        (maker2, maker2PK) = makeAddrAndKey("maker2");

        usdt = new MockStableCoin("USDT");
        sgd = new MockStableCoin("SGD");

        sera = _deploySera(owner);
        batcher = new SeraBatcher(address(sera));

        vm.startPrank(owner);
        _whitelistToken(sera, address(usdt), true, 1);
        _whitelistToken(sera, address(sgd), true, 1);
        sera.grantRole(sera.EXECUTOR_ROLE(), executor);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        vm.stopPrank();

        _mintAndDeposit(maker1, address(usdt), 10000 ether, sera);
        _mintAndDeposit(maker2, address(sgd), 10000 ether, sera);
    }

    // ======== Best-Effort Batch Tests ========

    function test_batchMatchOrders_Success() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(1000 ether, 100 ether, 1, 2);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        assertEq(failedMask, 0);
    }

    function test_batchMatchOrders_ContinuesOnError() public {
        MatchData[] memory matches = new MatchData[](2);
        matches[0] = _makePair(500 ether, 50 ether, 11, 12);
        matches[1] = _makePair(500 ether, 50 ether, 21, 22);
        matches[1].order0.expiration = uint48(block.timestamp - 1);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        assertEq(failedMask, 2);
    }

    function test_batchMatchOrders_RevertsIfTooManyOrders() public {
        MatchData[] memory matches = new MatchData[](21);
        vm.prank(executor);
        vm.expectRevert(SeraBatcher.TooManyOrders.selector);
        batcher.batchMatchOrders(matches);
    }

    function test_batchMatchOrders_RevertsIfCallerNotExecutorRoleInSera() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 31, 32);

        vm.expectRevert(abi.encodeWithSelector(SeraBase.Unauthorized.selector, address(this), sera.EXECUTOR_ROLE()));
        batcher.batchMatchOrders(matches);
    }

    // ======== FOK Atomic Batch Tests ========

    function test_batchMatchOrdersAtomic_Success() public {
        MatchData[] memory matches = new MatchData[](2);
        matches[0] = _makePair(300 ether, 30 ether, 1, 2);
        matches[1] = _makePair(700 ether, 70 ether, 3, 4);

        vm.prank(executor);
        batcher.batchMatchOrdersAtomic(matches);

        assertEq(usdt.balanceOf(maker2), 1000 ether);
        assertEq(sgd.balanceOf(maker1), 100 ether);
    }

    function test_batchMatchOrdersAtomic_RevertsOnAnyFailure() public {
        MatchData[] memory matches = new MatchData[](2);
        matches[0] = _makePair(500 ether, 50 ether, 11, 12);
        matches[1] = _makePair(500 ether, 50 ether, 21, 22);
        
        // Break the second match (expiration)
        matches[1].order0.expiration = uint48(block.timestamp - 1);

        uint256 beforeTakerUsdt = usdt.balanceOf(maker1);
        uint256 beforeMakerSgd = sgd.balanceOf(maker2);

        vm.prank(executor);
        vm.expectRevert(); // Will revert on the second match
        batcher.batchMatchOrdersAtomic(matches);

        // Verification: First match SHOULD be rolled back
        assertEq(usdt.balanceOf(maker1), beforeTakerUsdt, "Atomic: Taker USDT should be unchanged");
        assertEq(sgd.balanceOf(maker2), beforeMakerSgd, "Atomic: Maker SGD should be unchanged");
    }

    function test_batchMatchOrdersAtomic_RevertsIfNotExecutor() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 31, 32);

        vm.expectRevert(abi.encodeWithSelector(SeraBase.Unauthorized.selector, address(this), sera.EXECUTOR_ROLE()));
        batcher.batchMatchOrdersAtomic(matches);
    }

    // ======== Pause Tests ========

    function test_pause_UsesSeraPauserRole() public {
        vm.prank(owner);
        sera.pause();

        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 41, 42);

        vm.prank(executor);
        vm.expectRevert();
        batcher.batchMatchOrders(matches);

        vm.prank(owner);
        sera.unpause();

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        assertEq(failedMask, 0);
    }


    // ======== Mixed Batch Tests ========

    function test_batchMatchMixed_Success() public {
        SeraBatcher.AtomicBatch[] memory atomics = new SeraBatcher.AtomicBatch[](1);
        MatchData[] memory atomicMatches = new MatchData[](2);
        atomicMatches[0] = _makePair(500 ether, 50 ether, 101, 102);
        atomicMatches[1] = _makePair(500 ether, 50 ether, 103, 104);
        atomics[0] = SeraBatcher.AtomicBatch({matches: atomicMatches});

        MatchData[] memory singles = new MatchData[](1);
        singles[0] = _makePair(500 ether, 50 ether, 105, 106);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchMixed(atomics, singles);

        // 1 atomic, 1 single. Both successful = 0
        assertEq(failedMask, 0, "No batch or single failed");

        assertEq(usdt.balanceOf(maker2), 1500 ether);
    }

    function test_batchMatchMixed_PartialFailure() public {
        SeraBatcher.AtomicBatch[] memory atomics = new SeraBatcher.AtomicBatch[](2);
        
        // Atomic 1: Success
        MatchData[] memory m1 = new MatchData[](1);
        m1[0] = _makePair(100 ether, 10 ether, 201, 202);
        atomics[0] = SeraBatcher.AtomicBatch({matches: m1});

        // Atomic 2: Failure (expired)
        MatchData[] memory m2 = new MatchData[](1);
        m2[0] = _makePair(100 ether, 10 ether, 203, 204);
        m2[0].order0.expiration = uint48(block.timestamp - 1);
        atomics[1] = SeraBatcher.AtomicBatch({matches: m2});

        MatchData[] memory singles = new MatchData[](2);
        singles[0] = _makePair(100 ether, 10 ether, 205, 206);
        singles[1] = _makePair(100 ether, 10 ether, 207, 208);
        
        // Single 2: Failure (invalid amount)
        singles[1].matchAmount0 = 101 ether;

        vm.prank(executor);
        // Expect AtomicBatchFailed with index 1
        vm.expectEmit(false, false, false, true);
        emit SeraBatcher.AtomicBatchFailed(1, abi.encodeWithSelector(Sera.OrderExpired.selector));
        
        // Expect MatchFailed with index 3 (2 atomics + 1 single)
        vm.expectEmit(true, true, false, true);
        
        bytes32 h0 = keccak256(abi.encode(ORDER_TYPEHASH, singles[1].order0.user, singles[1].order0.expiration, singles[1].order0.feeBps, singles[1].order0.recipient, singles[1].order0.fromToken, singles[1].order0.toToken, singles[1].order0.fromAmount, singles[1].order0.toAmount, singles[1].order0.initialDepositAmount, singles[1].order0.routeHash, singles[1].order0.uuid));
        bytes32 h1 = keccak256(abi.encode(ORDER_TYPEHASH, singles[1].order1.user, singles[1].order1.expiration, singles[1].order1.feeBps, singles[1].order1.recipient, singles[1].order1.fromToken, singles[1].order1.toToken, singles[1].order1.fromAmount, singles[1].order1.toAmount, singles[1].order1.initialDepositAmount, singles[1].order1.routeHash, singles[1].order1.uuid));
        
        emit SeraBatcher.MatchFailed(
            h0, 
            h1, 
            abi.encodeWithSelector(Sera.OrderFilledAmountExceeded.selector), 
            3
        );
        uint256 failedMask = batcher.batchMatchMixed(atomics, singles);

        // Atomic 1 (index 0) passed
        // Atomic 2 (index 1) failed -> bit 1 should be set
        // Single 1 (index 2) passed
        // Single 2 (index 3) failed -> bit 3 should be set
        // Mask should be (1 << 1) | (1 << 3) = 2 + 8 = 10
        assertEq(failedMask, 10, "Atomic 2 and Single 2 failed");
    }

    function test_batchMatchMixed_Unauthorized() public {
        SeraBatcher.AtomicBatch[] memory atomics = new SeraBatcher.AtomicBatch[](0);
        MatchData[] memory singles = new MatchData[](0);

        vm.expectRevert(abi.encodeWithSelector(SeraBase.Unauthorized.selector, address(this), sera.EXECUTOR_ROLE()));
        batcher.batchMatchMixed(atomics, singles);
    }

    // ======== Failure Tests (Wrong Matches) ========

    function test_batchMatchOrders_CatchInvalidSignature() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 301, 302);
        
        // Corrupt maker signature
        matches[0].signature1 = bytes("invalid");

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        
        assertEq(failedMask, 1, "Match failure should be caught");
    }

    function test_batchMatchOrders_CatchTokenMismatch() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 401, 402);
        
        // Maker is selling something else
        matches[0].order1.fromToken = address(0xdead);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        
        assertEq(failedMask, 1, "Token mismatch should be caught");
    }

    function test_batchMatchOrders_CatchAmountMismatch() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 501, 502);
        
        // Match amount exceeds signed amount
        matches[0].matchAmount0 = 101 ether;

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches);
        
        assertEq(failedMask, 1, "Amount mismatch should be caught");
    }

    function test_batchMatchOrdersAtomic_RevertsInvalidSignature() public {
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _makePair(100 ether, 10 ether, 601, 602);
        
        // Corrupt taker signature
        matches[0].signature0 = bytes("invalid");

        vm.prank(executor);
        vm.expectRevert(); // Atomic should revert the whole tx
        batcher.batchMatchOrdersAtomic(matches);
    }

    function _makePair(uint256 usdtAmt, uint256 sgdAmt, uint256 uuid0, uint256 uuid1)
        internal
        view
        returns (MatchData memory)
    {
        Order memory o0 = Order({
            user: maker1,
            fromToken: address(usdt),
            toToken: address(sgd),
            fromAmount: usdtAmt,
            toAmount: sgdAmt,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: uuid0,
            routeHash: bytes32(0)
        });
        Order memory o1 = Order({
            user: maker2,
            fromToken: address(sgd),
            toToken: address(usdt),
            fromAmount: sgdAmt,
            toAmount: usdtAmt,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: maker2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: uuid1,
            routeHash: bytes32(0)
        });

        return MatchData({
            order0: o0,
            signature0: _signOrder(maker1PK, o0, sera),
            matchAmount0: usdtAmt,
            order1: o1,
            signature1: _signOrder(maker2PK, o1, sera),
            matchAmount1: sgdAmt
        });
    }
}
