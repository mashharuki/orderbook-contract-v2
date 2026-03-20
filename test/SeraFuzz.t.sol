// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/mock/MockStableCoin.sol";
import "../src/Sera.sol";
import "../src/SeraBatcher.sol";

import "./TestHelper.sol";

contract SeraFuzzTest is TestHelper {
    MockStableCoin USDT;
    MockStableCoin SGD;
    Sera orderBook;
    SeraBatcher batcher;
    address owner;
    uint256 ownerPK;
    address executor;

    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        executor = makeAddr("executor");

        USDT = new MockStableCoin("USDT");
        SGD = new MockStableCoin("SGD");

        orderBook = _deploySera(owner);
        batcher = new SeraBatcher(address(orderBook));

        vm.startPrank(owner);
        _whitelistToken(orderBook, address(USDT), true, 1);
        _whitelistToken(orderBook, address(SGD), true, 1);
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), address(this));
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), executor);
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), address(batcher));
        vm.stopPrank();
    }

    function _deposit(address user, address token, uint256 amount) internal {
        _mintAndDeposit(user, address(token), amount, orderBook);
    }

    function testFuzz_DepositUpdatesVaultBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max / 2);
        (address user,) = makeAddrAndKey("user");

        USDT.mint(user, amount);
        _deposit(user, address(USDT), amount);

        uint256 vaultBalance = orderBook.vault().balanceOf(address(USDT), user);
        assertEq(vaultBalance, amount);
    }

    function testFuzz_MatchOrderAccountingInvariant(uint256 fillRatioBps) public {
        fillRatioBps = bound(fillRatioBps, 1, 10000);

        (address user1, uint256 user1PK) = makeAddrAndKey("user1");
        (address user2, uint256 user2PK) = makeAddrAndKey("user2");

        uint256 orderAmount = 1000 ether;

        USDT.mint(user1, orderAmount);
        SGD.mint(user2, orderAmount);
        _deposit(user1, address(USDT), orderAmount);
        _deposit(user2, address(SGD), orderAmount);

        Order memory order1 = Order({user: user1, fromToken: address(USDT), toToken: address(SGD), fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0, feeBps: 0, recipient: user1, expiration: uint48(block.timestamp + 1 days), uuid: 1, routeHash: bytes32(0)});
        Order memory order2 = Order({user: user2, fromToken: address(SGD), toToken: address(USDT), fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0, feeBps: 0, recipient: user2, expiration: uint48(block.timestamp + 1 days), uuid: 2, routeHash: bytes32(0)});

        bytes memory sig1 = _signOrder(user1PK, order1, orderBook);
        bytes memory sig2 = _signOrder(user2PK, order2, orderBook);

        uint256 fillAmount = (orderAmount * fillRatioBps) / 10000;
        if (fillAmount == 0) fillAmount = 1;

        MatchData memory matchData = MatchData({order0: order1, signature0: sig1, matchAmount0: fillAmount, order1: order2, signature1: sig2, matchAmount1: fillAmount});

        orderBook.matchOrders(matchData, type(uint256).max);

        // Invariants
        // 1:1 match -> User1 gets `fillAmount` SGD
        assertEq(SGD.balanceOf(user1), fillAmount);
        assertEq(USDT.balanceOf(user2), fillAmount);
    }

    function testFuzz_MinOrderAmountEnforcement(uint256 minAmount, uint256 orderAmount) public {
        minAmount = bound(minAmount, 100, type(uint248).max);
        orderAmount = bound(orderAmount, 1, type(uint256).max / 2);

        vm.prank(owner);
        _whitelistToken(orderBook, address(USDT), true, minAmount);

        (address maker, uint256 makerPK) = makeAddrAndKey("maker");
        USDT.mint(maker, orderAmount);
        _deposit(maker, address(USDT), orderAmount);

        Order memory order1 = Order({user: maker, fromToken: address(USDT), toToken: address(SGD), fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0, feeBps: 0, recipient: maker, expiration: uint48(block.timestamp + 1 days), uuid: 1, routeHash: bytes32(0)});
        bytes memory sig1 = _signOrder(makerPK, order1, orderBook);

        // Perfect counterparty
        (address taker, uint256 takerPK) = makeAddrAndKey("taker");
        SGD.mint(taker, orderAmount);
        _deposit(taker, address(SGD), orderAmount);

        Order memory order2 = Order({user: taker, fromToken: address(SGD), toToken: address(USDT), fromAmount: orderAmount, toAmount: orderAmount, initialDepositAmount: 0, feeBps: 0, recipient: taker, expiration: uint48(block.timestamp + 1 days), uuid: 2, routeHash: bytes32(0)});
        bytes memory sig2 = _signOrder(takerPK, order2, orderBook);

        MatchData memory matchData = MatchData({order0: order1, signature0: sig1, matchAmount0: orderAmount, order1: order2, signature1: sig2, matchAmount1: orderAmount});

        if (orderAmount < minAmount) {
            // Because one of the orders is below min amount
            vm.expectRevert(abi.encodeWithSelector(Sera.AmountBelowMinimum.selector, orderAmount, minAmount));
            orderBook.matchOrders(matchData, type(uint256).max);
        } else {
            orderBook.matchOrders(matchData, type(uint256).max);
        }
    }

    function testFuzz_BatchWrapper_ContinueOnFailure(uint256 amount, bool makeSecondExpired) public {
        amount = bound(amount, 1 ether, 1000 ether);

        (address u1, uint256 u1pk) = makeAddrAndKey("fuzz_batch_u1");
        (address u2, uint256 u2pk) = makeAddrAndKey("fuzz_batch_u2");

        USDT.mint(u1, amount * 2);
        SGD.mint(u2, amount * 2);
        _deposit(u1, address(USDT), amount * 2);
        _deposit(u2, address(SGD), amount * 2);

        Order memory a1 = Order(u1, uint48(block.timestamp + 1 days), 0, u1, address(USDT), address(SGD), amount, amount, 0, bytes32(0), 11);
        Order memory b1 = Order(u2, uint48(block.timestamp + 1 days), 0, u2, address(SGD), address(USDT), amount, amount, 0, bytes32(0), 12);

        Order memory a2 = Order(u1, uint48(block.timestamp + 1 days), 0, u1, address(USDT), address(SGD), amount, amount, 0, bytes32(0), 21);
        Order memory b2 = Order(u2, uint48(block.timestamp + 1 days), 0, u2, address(SGD), address(USDT), amount, amount, 0, bytes32(0), 22);
        if (makeSecondExpired) a2.expiration = uint48(block.timestamp - 1);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(a1, _signOrder(u1pk, a1, orderBook), amount, b1, _signOrder(u2pk, b1, orderBook), amount);
        matches[1] = MatchData(a2, _signOrder(u1pk, a2, orderBook), amount, b2, _signOrder(u2pk, b2, orderBook), amount);

        vm.prank(executor);
        uint256 failedMask = batcher.batchMatchOrders(matches, type(uint256).max);

        if (makeSecondExpired) assertEq(failedMask, 2);
        else assertEq(failedMask, 0);
    }

    function testFuzz_FOKWrapper_Atomicity(uint256 amount) public {
        amount = bound(amount, 1 ether, 1000 ether);

        (address u1, uint256 u1pk) = makeAddrAndKey("fuzz_fok_u1");
        (address u2, uint256 u2pk) = makeAddrAndKey("fuzz_fok_u2");

        USDT.mint(u1, amount * 2);
        SGD.mint(u2, amount * 2);
        _deposit(u1, address(USDT), amount * 2);
        _deposit(u2, address(SGD), amount * 2);

        Order memory a1 = Order(u1, uint48(block.timestamp + 1 days), 0, u1, address(USDT), address(SGD), amount, amount, 0, bytes32(0), 31);
        Order memory b1 = Order(u2, uint48(block.timestamp + 1 days), 0, u2, address(SGD), address(USDT), amount, amount, 0, bytes32(0), 32);
        Order memory a2 = Order(u1, uint48(block.timestamp - 1), 0, u1, address(USDT), address(SGD), amount, amount, 0, bytes32(0), 33);
        Order memory b2 = Order(u2, uint48(block.timestamp + 1 days), 0, u2, address(SGD), address(USDT), amount, amount, 0, bytes32(0), 34);

        MatchData[] memory matches = new MatchData[](2);
        matches[0] = MatchData(a1, _signOrder(u1pk, a1, orderBook), amount, b1, _signOrder(u2pk, b1, orderBook), amount);
        matches[1] = MatchData(a2, _signOrder(u1pk, a2, orderBook), amount, b2, _signOrder(u2pk, b2, orderBook), amount);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Sera.OrderExpired.selector));
        batcher.batchMatchOrdersAtomic(matches, type(uint256).max);
    }
}
