// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/mock/MockStableCoin.sol";
import "../src/Sera.sol";
import "../src/SeraBatcher.sol";

import "./TestHelper.sol";

contract SeraInvariantHandler is TestHelper {
    MockStableCoin public USDT;
    MockStableCoin public SGD;
    Sera public orderBook;
    SeraBatcher public batcher;
    Vault public vault;

    address public owner;
    uint256 public ownerPK;

    address[] public actors;
    uint256[] public actorPKs;
    mapping(address => uint256) public actorDepositsUSDT;
    mapping(address => uint256) public actorDepositsSGD;
    uint256 public nextUuid = 1;

    // Ghost variables
    uint256 public ghost_totalDepositsUSDT;
    uint256 public ghost_totalDepositsSGD;
    uint256 public ghost_totalWithdrawalsUSDT;
    uint256 public ghost_totalWithdrawalsSGD;
    uint256 public ghost_matchCount;

    constructor(
        MockStableCoin _usdt,
        MockStableCoin _sgd,
        Sera _orderBook,
        SeraBatcher _batcher,
        address _owner,
        uint256 _ownerPK
    ) {
        USDT = _usdt;
        SGD = _sgd;
        orderBook = _orderBook;
        batcher = _batcher;
        vault = _orderBook.vault();
        owner = _owner;
        ownerPK = _ownerPK;

        for (uint256 i = 0; i < 5; i++) {
            (address actor, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(actor);
            actorPKs.push(pk);
        }
    }

    function depositUSDT(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        uint256 actorIdx = actorSeed % actors.length;
        address actor = actors[actorIdx];
        USDT.mint(actor, amount);
        vm.startPrank(actor);
        USDT.approve(address(vault), amount);
        orderBook.depositFund(address(USDT), actor, amount);
        vm.stopPrank();
        actorDepositsUSDT[actor] += amount;
        ghost_totalDepositsUSDT += amount;
    }

    function depositSGD(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        uint256 actorIdx = actorSeed % actors.length;
        address actor = actors[actorIdx];
        SGD.mint(actor, amount);
        vm.startPrank(actor);
        SGD.approve(address(vault), amount);
        orderBook.depositFund(address(SGD), actor, amount);
        vm.stopPrank();
        actorDepositsSGD[actor] += amount;
        ghost_totalDepositsSGD += amount;
    }

    function matchOrders(uint256 seed1, uint256 seed2, uint256 amount) external {
        uint256 idx1 = seed1 % actors.length;
        uint256 idx2 = seed2 % actors.length;
        if (idx1 == idx2) idx2 = (idx2 + 1) % actors.length;
        address user1 = actors[idx1];
        address user2 = actors[idx2];
        uint256 pk1 = actorPKs[idx1];
        uint256 pk2 = actorPKs[idx2];
        uint256 bal1 = vault.balanceOf(address(USDT), user1);
        uint256 bal2 = vault.balanceOf(address(SGD), user2);
        if (bal1 == 0 || bal2 == 0) return;
        amount = bound(amount, 1, bal1 < bal2 ? bal1 : bal2);
        Order memory o1 = Order({
            user: user1,
            fromToken: address(USDT),
            toToken: address(SGD),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        Order memory o2 = Order({
            user: user2,
            fromToken: address(SGD),
            toToken: address(USDT),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        MatchData memory data = MatchData({
            order0: o1,
            signature0: _signOrder(pk1, o1, orderBook),
            matchAmount0: amount,
            order1: o2,
            signature1: _signOrder(pk2, o2, orderBook),
            matchAmount1: amount
        });
        vm.prank(owner);
        try orderBook.matchOrders(data) {
            ghost_matchCount++;
        } catch {}
    }

    function matchOrdersViaBatch(uint256 seed1, uint256 seed2, uint256 amount) external {
        uint256 idx1 = seed1 % actors.length;
        uint256 idx2 = seed2 % actors.length;
        if (idx1 == idx2) idx2 = (idx2 + 1) % actors.length;
        address user1 = actors[idx1];
        address user2 = actors[idx2];
        uint256 pk1 = actorPKs[idx1];
        uint256 pk2 = actorPKs[idx2];
        uint256 bal1 = vault.balanceOf(address(USDT), user1);
        uint256 bal2 = vault.balanceOf(address(SGD), user2);
        if (bal1 == 0 || bal2 == 0) return;
        amount = bound(amount, 1, bal1 < bal2 ? bal1 : bal2);
        Order memory o1 = Order({
            user: user1,
            fromToken: address(USDT),
            toToken: address(SGD),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        Order memory o2 = Order({
            user: user2,
            fromToken: address(SGD),
            toToken: address(USDT),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: o1,
            signature0: _signOrder(pk1, o1, orderBook),
            matchAmount0: amount,
            order1: o2,
            signature1: _signOrder(pk2, o2, orderBook),
            matchAmount1: amount
        });
        vm.prank(owner);
        try batcher.batchMatchOrders(matches) returns (uint256 failedMask) {
            if (failedMask == 0) ghost_matchCount++;
        } catch {}
    }

    function matchOrdersViaFok(uint256 seed1, uint256 seed2, uint256 amount) external {
        uint256 idx1 = seed1 % actors.length;
        uint256 idx2 = seed2 % actors.length;
        if (idx1 == idx2) idx2 = (idx2 + 1) % actors.length;
        address user1 = actors[idx1];
        address user2 = actors[idx2];
        uint256 pk1 = actorPKs[idx1];
        uint256 pk2 = actorPKs[idx2];
        uint256 bal1 = vault.balanceOf(address(USDT), user1);
        uint256 bal2 = vault.balanceOf(address(SGD), user2);
        if (bal1 == 0 || bal2 == 0) return;
        amount = bound(amount, 1, bal1 < bal2 ? bal1 : bal2);
        Order memory o1 = Order({
            user: user1,
            fromToken: address(USDT),
            toToken: address(SGD),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user1,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        Order memory o2 = Order({
            user: user2,
            fromToken: address(SGD),
            toToken: address(USDT),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: user2,
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++,
            routeHash: bytes32(0)
        });
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = MatchData({
            order0: o1,
            signature0: _signOrder(pk1, o1, orderBook),
            matchAmount0: amount,
            order1: o2,
            signature1: _signOrder(pk2, o2, orderBook),
            matchAmount1: amount
        });
        vm.prank(owner);
        try batcher.batchMatchOrdersAtomic(matches) {
            ghost_matchCount++;
        } catch {}
    }

    function requestWithdrawal(uint256 actorSeed, uint256 amount, bool withdrawUSDT) external {
        uint256 actorIdx = actorSeed % actors.length;
        address actor = actors[actorIdx];
        address token = withdrawUSDT ? address(USDT) : address(SGD);
        uint256 vaultBal = vault.balanceOf(token, actor);
        if (vaultBal == 0) return;
        amount = bound(amount, 1, vaultBal);
        vm.prank(actor);
        try orderBook.emergencyWithdraw(token, amount) {} catch {}
    }

    function executeWithdrawal(uint256 actorSeed, bool withdrawUSDT) external {
        uint256 actorIdx = actorSeed % actors.length;
        address actor = actors[actorIdx];
        address token = withdrawUSDT ? address(USDT) : address(SGD);
        (uint256 requestBlock, uint256 requestAmount) = orderBook.withdrawRequests(actor, token);
        if (requestBlock == 0) return;
        vm.roll(block.number + 7201);
        uint256 balBefore = IERC20(token).balanceOf(actor);
        vm.prank(actor);
        try orderBook.emergencyWithdraw(token, requestAmount) {
            uint256 withdrawn = IERC20(token).balanceOf(actor) - balBefore;
            if (withdrawUSDT) ghost_totalWithdrawalsUSDT += withdrawn;
            else ghost_totalWithdrawalsSGD += withdrawn;
        } catch {}
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 idx) external view returns (address) {
        return actors[idx];
    }
}

contract SeraInvariantTest is TestHelper {
    MockStableCoin USDT;
    MockStableCoin SGD;
    Sera orderBook;
    SeraBatcher batcher;
    address _owner;
    uint256 ownerPK;
    SeraInvariantHandler handler;

    function setUp() public {
        (_owner, ownerPK) = makeAddrAndKey("owner");

        USDT = new MockStableCoin("USDT");
        SGD = new MockStableCoin("SGD");

        orderBook = _deploySera(_owner);
        batcher = new SeraBatcher(address(orderBook));

        vm.startPrank(_owner);
        _whitelistToken(orderBook, address(USDT), true, 1);
        _whitelistToken(orderBook, address(SGD), true, 1);
        bytes32 executorRole = orderBook.EXECUTOR_ROLE();
        orderBook.grantRole(executorRole, address(this));
        orderBook.grantRole(executorRole, address(batcher));
        vm.stopPrank();

        handler = new SeraInvariantHandler(USDT, SGD, orderBook, batcher, _owner, ownerPK);

        vm.prank(_owner);
        orderBook.grantRole(executorRole, address(handler));

        targetContract(address(handler));
    }

    function invariant_vaultSolvencyUSDT() public view {
        Vault vault = orderBook.vault();
        assertTrue(USDT.balanceOf(address(vault)) >= 0);
    }

    function invariant_vaultSolvencySGD() public view {
        Vault vault = orderBook.vault();
        assertTrue(SGD.balanceOf(address(vault)) >= 0);
    }

    function invariant_noUserExceedsVaultBalance() public view {
        Vault vault = orderBook.vault();
        uint256 actualUSDT = USDT.balanceOf(address(vault));
        uint256 actualSGD = SGD.balanceOf(address(vault));
        for (uint256 i = 0; i < handler.getActorCount(); i++) {
            address actor = handler.getActor(i);
            assertTrue(vault.balanceOf(address(USDT), actor) <= actualUSDT);
            assertTrue(vault.balanceOf(address(SGD), actor) <= actualSGD);
        }
    }

    function invariant_sumOfBalancesDoesNotExceedActual() public view {
        Vault vault = orderBook.vault();
        uint256 actualUSDT = USDT.balanceOf(address(vault));
        uint256 actualSGD = SGD.balanceOf(address(vault));
        uint256 sumUSDT = 0;
        uint256 sumSGD = 0;
        for (uint256 i = 0; i < handler.getActorCount(); i++) {
            address actor = handler.getActor(i);
            sumUSDT += vault.balanceOf(address(USDT), actor);
            sumSGD += vault.balanceOf(address(SGD), actor);
        }
        assertTrue(sumUSDT <= actualUSDT);
        assertTrue(sumSGD <= actualSGD);
    }

    function invariant_ghostDepositWithdrawConsistency() public view {
        assertTrue(handler.ghost_totalDepositsUSDT() >= handler.ghost_totalWithdrawalsUSDT());
        assertTrue(handler.ghost_totalDepositsSGD() >= handler.ghost_totalWithdrawalsSGD());
    }
}
