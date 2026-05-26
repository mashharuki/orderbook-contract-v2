// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Vault.sol";
import "../../src/mock/MockStableCoin.sol";

/**
 * @title VaultSymbolic - Halmos symbolic execution tests for Vault
 * @notice Uses symbolic execution to formally verify Vault properties
 * @dev Halmos test functions must be prefixed with `check_`
 */
contract VaultSymbolic is Test {
    Vault public vault;
    MockStableCoin public token;
    
    address public admin;
    address public trader;
    
    function setUp() public {
        admin = address(0x1000);
        trader = address(0x2000);
        
        token = new MockStableCoin("TEST");
        vault = new Vault(admin);
        
        // Use low-level call to avoid Halmos issues with vm.prank
        bytes32 traderRole = vault.TRADER_ROLE();
        vm.prank(admin);
        vault.grantRole(traderRole, trader);
    }
    
    // ============ Deposit Properties ============
    
    /**
     * @notice Verify deposit increases user balance by exact amount
     */
    function check_depositIncreasesBalance(address user, uint256 amount) public {
        // Preconditions
        vm.assume(user != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(!vault.isBlacklisted(user));
        
        // Setup
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);
        
        uint256 balanceBefore = vault.balanceOf(address(token), user);
        
        // Action
        vm.prank(trader);
        vault.deposit(user, address(token), amount);
        
        uint256 balanceAfter = vault.balanceOf(address(token), user);
        
        // Postcondition: balance increased by exact amount
        assert(balanceAfter == balanceBefore + amount);
    }
    
    /**
     * @notice Verify deposit fails for blacklisted users
     */
    function check_depositFailsForBlacklisted(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        // Blacklist user
        vm.prank(admin);
        vault.setBlacklisted(user, true);
        
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);
        
        // Should revert
        vm.prank(trader);
        vm.expectRevert();
        vault.deposit(user, address(token), amount);
    }
    
    /**
     * @notice Verify deposit fails for zero amount
     */
    function check_depositFailsForZeroAmount(address user) public {
        vm.assume(user != address(0));
        vm.assume(!vault.isBlacklisted(user));
        
        vm.prank(trader);
        vm.expectRevert();
        vault.deposit(user, address(token), 0);
    }
    
    // ============ Withdraw Properties ============
    
    /**
     * @notice Verify withdraw decreases balance by exact amount
     */
    function check_withdrawDecreasesBalance(address user, uint256 depositAmount, uint256 withdrawAmount) public {
        vm.assume(user != address(0));
        vm.assume(depositAmount > 0 && depositAmount < type(uint128).max);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        
        // Setup: deposit first
        token.mint(user, depositAmount);
        vm.prank(user);
        token.approve(address(vault), depositAmount);
        vm.prank(trader);
        vault.deposit(user, address(token), depositAmount);
        
        uint256 balanceBefore = vault.balanceOf(address(token), user);
        
        // Action
        vm.prank(trader);
        vault.withdraw(user, address(token), withdrawAmount, user);
        
        uint256 balanceAfter = vault.balanceOf(address(token), user);
        
        // Postcondition
        assert(balanceAfter == balanceBefore - withdrawAmount);
    }
    
    /**
     * @notice Verify withdraw fails when amount exceeds balance
     */
    function check_withdrawFailsOnInsufficientBalance(address user, uint256 depositAmount, uint256 withdrawAmount) public {
        vm.assume(user != address(0));
        vm.assume(depositAmount > 0 && depositAmount < type(uint128).max);
        vm.assume(withdrawAmount > depositAmount);
        
        // Setup
        token.mint(user, depositAmount);
        vm.prank(user);
        token.approve(address(vault), depositAmount);
        vm.prank(trader);
        vault.deposit(user, address(token), depositAmount);
        
        // Should revert
        vm.prank(trader);
        vm.expectRevert();
        vault.withdraw(user, address(token), withdrawAmount, user);
    }
    
    // ============ Transfer Ledger Properties ============
    
    /**
     * @notice Verify transferLedger preserves total balance
     */
    function check_transferPreservesTotal(
        address fromUser,
        address toUser,
        uint256 depositAmount,
        uint256 transferAmount
    ) public {
        vm.assume(fromUser != address(0) && toUser != address(0));
        vm.assume(fromUser != toUser);
        vm.assume(depositAmount > 0 && depositAmount < type(uint128).max);
        vm.assume(transferAmount > 0 && transferAmount <= depositAmount);
        vm.assume(!vault.isBlacklisted(toUser));
        
        // Setup
        token.mint(fromUser, depositAmount);
        vm.prank(fromUser);
        token.approve(address(vault), depositAmount);
        vm.prank(trader);
        vault.deposit(fromUser, address(token), depositAmount);
        
        uint256 fromBefore = vault.balanceOf(address(token), fromUser);
        uint256 toBefore = vault.balanceOf(address(token), toUser);
        uint256 totalBefore = fromBefore + toBefore;
        
        // Action
        vm.prank(trader);
        vault.transferLedger(fromUser, toUser, address(token), transferAmount);
        
        uint256 fromAfter = vault.balanceOf(address(token), fromUser);
        uint256 toAfter = vault.balanceOf(address(token), toUser);
        uint256 totalAfter = fromAfter + toAfter;
        
        // Postcondition: total preserved
        assert(totalAfter == totalBefore);
        assert(fromAfter == fromBefore - transferAmount);
        assert(toAfter == toBefore + transferAmount);
    }
    
    /**
     * @notice Verify transferLedger fails to blacklisted recipient
     */
    function check_transferFailsToBlacklisted(
        address fromUser,
        address toUser,
        uint256 amount
    ) public {
        vm.assume(fromUser != address(0) && toUser != address(0));
        vm.assume(fromUser != toUser);
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        // Setup
        token.mint(fromUser, amount);
        vm.prank(fromUser);
        token.approve(address(vault), amount);
        vm.prank(trader);
        vault.deposit(fromUser, address(token), amount);
        
        // Blacklist recipient
        vm.prank(admin);
        vault.setBlacklisted(toUser, true);
        
        // Should revert
        vm.prank(trader);
        vm.expectRevert();
        vault.transferLedger(fromUser, toUser, address(token), amount);
    }
    
    // ============ Access Control Properties ============
    
    /**
     * @notice Verify only trader role can deposit
     */
    function check_onlyTraderCanDeposit(address caller, address user, uint256 amount) public {
        vm.assume(caller != trader);
        vm.assume(user != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(!vault.hasRole(vault.TRADER_ROLE(), caller));
        
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);
        
        vm.prank(caller);
        vm.expectRevert();
        vault.deposit(user, address(token), amount);
    }
    
    /**
     * @notice Verify only admin can set blacklist
     */
    function check_onlyAdminCanBlacklist(address caller, address user) public {
        vm.assume(caller != admin);
        vm.assume(user != address(0));
        vm.assume(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), caller));
        
        vm.prank(caller);
        vm.expectRevert();
        vault.setBlacklisted(user, true);
    }
    
    // ============ Solvency Properties ============
    
    /**
     * @notice Verify vault actual balance >= user ledger balance after any operation
     */
    function check_vaultSolvencyAfterDeposit(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(!vault.isBlacklisted(user));
        
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);
        
        vm.prank(trader);
        vault.deposit(user, address(token), amount);
        
        uint256 actualBalance = token.balanceOf(address(vault));
        uint256 userBalance = vault.balanceOf(address(token), user);
        
        assert(actualBalance >= userBalance);
    }
    
    /**
     * @notice Verify vault solvency after withdraw
     */
    function check_vaultSolvencyAfterWithdraw(
        address user,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(depositAmount > 0 && depositAmount < type(uint128).max);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        
        token.mint(user, depositAmount);
        vm.prank(user);
        token.approve(address(vault), depositAmount);
        vm.prank(trader);
        vault.deposit(user, address(token), depositAmount);
        
        vm.prank(trader);
        vault.withdraw(user, address(token), withdrawAmount, user);
        
        uint256 actualBalance = token.balanceOf(address(vault));
        uint256 userBalance = vault.balanceOf(address(token), user);
        
        assert(actualBalance >= userBalance);
    }
}
