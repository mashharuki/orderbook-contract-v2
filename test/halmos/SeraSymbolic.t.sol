// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Sera.sol";
import "../../src/SeraSOR.sol";
import "../../src/SeraBatcher.sol";
import "../../src/mock/MockStableCoin.sol";
import "../TestHelper.sol";

/**
 * @title SeraSymbolic - Halmos symbolic execution tests for Sera
 * @notice Uses symbolic execution to formally verify Sera properties
 * @dev Halmos test functions must be prefixed with `check_`
 */
contract SeraSymbolic is TestHelper {
    Sera public sera;
    Vault public vault;
    SeraSOR public sor;
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    address public owner;
    uint256 public ownerPK;
    
    address public user1;
    uint256 public user1PK;
    
    address public user2;
    uint256 public user2PK;
    
    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("owner");
        (user1, user1PK) = makeAddrAndKey("user1");
        (user2, user2PK) = makeAddrAndKey("user2");
        
        tokenA = new MockStableCoin("TokenA");
        tokenB = new MockStableCoin("TokenB");
        
        vm.startPrank(owner);
        vault = new Vault(owner);
        sera = new Sera(owner, vault);
        vault.grantRole(vault.TRADER_ROLE(), address(sera));
        sor = new SeraSOR(address(sera));
        
        _whitelistToken(sera, address(tokenA), true, 1);
        _whitelistToken(sera, address(tokenB), true, 1);
        
        sera.grantRole(sera.EXECUTOR_ROLE(), owner);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        sera.setTreasury(owner);
        vm.stopPrank();
    }
    
    // ============ Order Matching Properties ============
    
    /**
     * @notice Verify filled amount never exceeds order fromAmount
     */
    function check_filledAmountBounded(
        uint256 fromAmount,
        uint256 toAmount,
        uint256 matchAmount
    ) public {
        vm.assume(fromAmount > 0 && fromAmount < type(uint128).max);
        vm.assume(toAmount > 0 && toAmount < type(uint128).max);
        vm.assume(matchAmount > 0 && matchAmount <= fromAmount);
        
        // Setup users with funds
        _mintAndDeposit(user1, address(tokenA), fromAmount, sera);
        _mintAndDeposit(user2, address(tokenB), toAmount, sera);
        
        uint256 uuid1 = 1;
        uint256 uuid2 = 2;
        
        Order memory order1 = Order({
            user: user1,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user1,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: fromAmount,
            toAmount: toAmount,
            initialDepositAmount: 0,
            uuid: uuid1
        });
        
        Order memory order2 = Order({
            user: user2,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user2,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: toAmount,
            toAmount: fromAmount,
            initialDepositAmount: 0,
            uuid: uuid2
        });
        
        bytes memory sig1 = _signOrder(user1PK, order1, sera);
        bytes memory sig2 = _signOrder(user2PK, order2, sera);
        
        MatchData memory matchData = MatchData({
            order0: order1,
            order1: order2,
            signature0: sig1,
            signature1: sig2,
            matchAmount0: matchAmount,
            matchAmount1: matchAmount
        });
        
        vm.prank(owner);
        try sera.matchOrders(matchData, block.timestamp + 1 hours) {
            // Verify filled amount is bounded
            bytes32 orderHash = _getOrderHashMemory(order1);
            uint256 filled = sera.filledAmount(orderHash);
            assert(filled <= fromAmount);
        } catch {}
    }
    
    /**
     * @notice Verify self-match is prevented
     */
    function check_selfMatchPrevented(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        _mintAndDeposit(user1, address(tokenA), amount, sera);
        _mintAndDeposit(user1, address(tokenB), amount, sera);
        
        Order memory order = Order({
            user: user1,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user1,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: 1
        });
        
        bytes memory sig = _signOrder(user1PK, order, sera);
        
        MatchData memory matchData = MatchData({
            order0: order,
            order1: order,
            signature0: sig,
            signature1: sig,
            matchAmount0: amount,
            matchAmount1: amount
        });
        
        vm.prank(owner);
        vm.expectRevert();
        sera.matchOrders(matchData, block.timestamp + 1 hours);
    }
    
    /**
     * @notice Verify same-token match is prevented
     */
    function check_sameTokenMatchPrevented(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        _mintAndDeposit(user1, address(tokenA), amount, sera);
        _mintAndDeposit(user2, address(tokenA), amount, sera);
        
        Order memory order1 = Order({
            user: user1,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user1,
            fromToken: address(tokenA),
            toToken: address(tokenA),  // Same token!
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: 1
        });
        
        Order memory order2 = Order({
            user: user2,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user2,
            fromToken: address(tokenA),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: 2
        });
        
        bytes memory sig1 = _signOrder(user1PK, order1, sera);
        bytes memory sig2 = _signOrder(user2PK, order2, sera);
        
        MatchData memory matchData = MatchData({
            order0: order1,
            order1: order2,
            signature0: sig1,
            signature1: sig2,
            matchAmount0: amount,
            matchAmount1: amount
        });
        
        vm.prank(owner);
        vm.expectRevert();
        sera.matchOrders(matchData, block.timestamp + 1 hours);
    }
    
    /**
     * @notice Verify UUID replay is prevented
     */
    function check_uuidReplayPrevented(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint64).max);
        
        _mintAndDeposit(user1, address(tokenA), amount * 2, sera);
        _mintAndDeposit(user2, address(tokenB), amount * 2, sera);
        
        uint256 uuid = 12345;
        
        Order memory order1 = Order({
            user: user1,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user1,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: uuid
        });
        
        Order memory order2 = Order({
            user: user2,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user2,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: uuid + 1
        });
        
        bytes memory sig1 = _signOrder(user1PK, order1, sera);
        bytes memory sig2 = _signOrder(user2PK, order2, sera);
        
        MatchData memory matchData = MatchData({
            order0: order1,
            order1: order2,
            signature0: sig1,
            signature1: sig2,
            matchAmount0: amount,
            matchAmount1: amount
        });
        
        // First match should succeed
        vm.prank(owner);
        sera.matchOrders(matchData, block.timestamp + 1 hours);
        
        // Second match with same order should fail (fully filled)
        vm.prank(owner);
        vm.expectRevert();
        sera.matchOrders(matchData, block.timestamp + 1 hours);
    }
    
    // ============ Withdrawal Properties ============
    
    /**
     * @notice Verify withdrawal delay is enforced
     */
    function check_withdrawalDelayEnforced(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        _mintAndDeposit(user1, address(tokenA), amount, sera);
        
        // Request withdrawal
        vm.prank(user1);
        sera.emergencyWithdraw(address(tokenA), amount);
        
        // Try to execute immediately (should fail)
        vm.prank(user1);
        vm.expectRevert();
        sera.emergencyWithdraw(address(tokenA), amount);
    }
    
    /**
     * @notice Verify withdrawal succeeds after delay
     */
    function check_withdrawalSucceedsAfterDelay(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        _mintAndDeposit(user1, address(tokenA), amount, sera);
        
        // Request withdrawal
        vm.prank(user1);
        sera.emergencyWithdraw(address(tokenA), amount);
        
        // Fast forward past delay
        vm.roll(block.number + sera.WITHDRAW_DELAY_BLOCKS() + 1);
        
        uint256 balanceBefore = tokenA.balanceOf(user1);
        
        // Execute withdrawal
        vm.prank(user1);
        sera.emergencyWithdraw(address(tokenA), amount);
        
        uint256 balanceAfter = tokenA.balanceOf(user1);
        
        assert(balanceAfter == balanceBefore + amount);
    }
    
    // ============ Constants Properties ============
    
    /**
     * @notice Verify constants are immutable
     */
    function check_constantsImmutable() public view {
        assert(sera.WITHDRAW_DELAY_BLOCKS() == 7200);
        assert(sera.MAX_EXPIRATION() == 365 days);
    }
    
    // ============ Access Control Properties ============
    
    /**
     * @notice Verify only executor can match orders
     */
    function check_onlyExecutorCanMatch(address caller, uint256 amount) public {
        vm.assume(caller != owner && caller != address(sor));
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(!sera.hasRole(sera.EXECUTOR_ROLE(), caller));
        
        _mintAndDeposit(user1, address(tokenA), amount, sera);
        _mintAndDeposit(user2, address(tokenB), amount, sera);
        
        Order memory order1 = Order({
            user: user1,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user1,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: 1
        });
        
        Order memory order2 = Order({
            user: user2,
            expiration: uint48(block.timestamp + 1 hours),
            feeBps: 0,
            recipient: user2,
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            uuid: 2
        });
        
        bytes memory sig1 = _signOrder(user1PK, order1, sera);
        bytes memory sig2 = _signOrder(user2PK, order2, sera);
        
        MatchData memory matchData = MatchData({
            order0: order1,
            order1: order2,
            signature0: sig1,
            signature1: sig2,
            matchAmount0: amount,
            matchAmount1: amount
        });
        
        vm.prank(caller);
        vm.expectRevert();
        sera.matchOrders(matchData, block.timestamp + 1 hours);
    }
}
