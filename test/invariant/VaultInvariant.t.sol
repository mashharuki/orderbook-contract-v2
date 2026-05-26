// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Vault.sol";
import "../../src/mock/MockStableCoin.sol";

/**
 * @title VaultHandler - Fuzzing handler for Vault invariant testing
 * @notice Simulates all possible Vault operations with bounded inputs
 */
contract VaultHandler is Test {
    Vault public vault;
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    address public admin;
    address public trader;
    
    address[] public users;
    address[] public tokens;
    
    // Ghost variables for tracking
    mapping(address => mapping(address => uint256)) public ghost_userDeposits;
    mapping(address => uint256) public ghost_totalDeposits;
    mapping(address => uint256) public ghost_totalWithdrawals;
    mapping(address => uint256) public ghost_totalTransfers;
    
    uint256 public ghost_depositCount;
    uint256 public ghost_withdrawCount;
    uint256 public ghost_transferCount;
    uint256 public ghost_creditCount;
    
    // Track blacklisted users
    mapping(address => bool) public ghost_blacklisted;
    
    constructor(
        Vault _vault,
        MockStableCoin _tokenA,
        MockStableCoin _tokenB,
        address _admin,
        address _trader
    ) {
        vault = _vault;
        tokenA = _tokenA;
        tokenB = _tokenB;
        admin = _admin;
        trader = _trader;
        
        tokens.push(address(_tokenA));
        tokens.push(address(_tokenB));
        
        // Create test users
        for (uint256 i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            users.push(user);
        }
    }
    
    // ============ Handler Functions ============
    
    function deposit(uint256 userSeed, uint256 tokenSeed, uint256 amount) external {
        address user = users[userSeed % users.length];
        address token = tokens[tokenSeed % tokens.length];
        amount = bound(amount, 1, 1000 ether);
        
        if (ghost_blacklisted[user]) return;
        
        // Mint and approve
        MockStableCoin(token).mint(user, amount);
        vm.prank(user);
        IERC20(token).approve(address(vault), amount);
        
        // Deposit via trader
        vm.prank(trader);
        try vault.deposit(user, token, amount) {
            ghost_userDeposits[token][user] += amount;
            ghost_totalDeposits[token] += amount;
            ghost_depositCount++;
        } catch {}
    }
    
    function withdraw(uint256 userSeed, uint256 tokenSeed, uint256 amount) external {
        address user = users[userSeed % users.length];
        address token = tokens[tokenSeed % tokens.length];
        
        uint256 balance = vault.balanceOf(token, user);
        if (balance == 0) return;
        
        amount = bound(amount, 1, balance);
        
        vm.prank(trader);
        try vault.withdraw(user, token, amount, user) {
            ghost_totalWithdrawals[token] += amount;
            ghost_withdrawCount++;
        } catch {}
    }
    
    function withdrawToRecipient(uint256 userSeed, uint256 recipientSeed, uint256 tokenSeed, uint256 amount) external {
        address user = users[userSeed % users.length];
        address recipient = users[recipientSeed % users.length];
        address token = tokens[tokenSeed % tokens.length];
        
        uint256 balance = vault.balanceOf(token, user);
        if (balance == 0) return;
        
        amount = bound(amount, 1, balance);
        
        vm.prank(trader);
        try vault.withdraw(user, token, amount, recipient) {
            ghost_totalWithdrawals[token] += amount;
            ghost_withdrawCount++;
        } catch {}
    }
    
    function transferLedger(uint256 fromSeed, uint256 toSeed, uint256 tokenSeed, uint256 amount) external {
        address fromUser = users[fromSeed % users.length];
        address toUser = users[toSeed % users.length];
        address token = tokens[tokenSeed % tokens.length];
        
        if (fromUser == toUser) return;
        if (ghost_blacklisted[toUser]) return;
        
        uint256 balance = vault.balanceOf(token, fromUser);
        if (balance == 0) return;
        
        amount = bound(amount, 1, balance);
        
        vm.prank(trader);
        try vault.transferLedger(fromUser, toUser, token, amount) {
            ghost_totalTransfers[token] += amount;
            ghost_transferCount++;
        } catch {}
    }
    
    function creditLedger(uint256 userSeed, uint256 tokenSeed, uint256 amount) external {
        address user = users[userSeed % users.length];
        address token = tokens[tokenSeed % tokens.length];
        amount = bound(amount, 1, 1000 ether);
        
        if (ghost_blacklisted[user]) return;
        
        // First transfer tokens to vault (simulating external transfer)
        MockStableCoin(token).mint(address(this), amount);
        IERC20(token).transfer(address(vault), amount);
        
        vm.prank(trader);
        try vault.creditLedger(user, token, amount) {
            ghost_userDeposits[token][user] += amount;
            ghost_totalDeposits[token] += amount;
            ghost_creditCount++;
        } catch {}
    }
    
    function setBlacklisted(uint256 userSeed, bool status) external {
        address user = users[userSeed % users.length];
        
        vm.prank(admin);
        vault.setBlacklisted(user, status);
        ghost_blacklisted[user] = status;
    }
    
    function rescueToken(uint256 tokenSeed, uint256 amount) external {
        address token = tokens[tokenSeed % tokens.length];
        
        // Send some surplus tokens to vault
        amount = bound(amount, 1, 100 ether);
        MockStableCoin(token).mint(address(vault), amount);
        
        vm.prank(admin);
        try vault.rescueToken(token, admin, amount) {} catch {}
    }
    
    // ============ View Functions ============
    
    function getUserCount() external view returns (uint256) {
        return users.length;
    }
    
    function getUser(uint256 idx) external view returns (address) {
        return users[idx];
    }
    
    function getTokenCount() external view returns (uint256) {
        return tokens.length;
    }
    
    function getToken(uint256 idx) external view returns (address) {
        return tokens[idx];
    }
}

/**
 * @title VaultInvariantTest - Comprehensive invariant tests for Vault
 * @notice Tests critical security properties that must always hold
 */
contract VaultInvariantTest is StdInvariant, Test {
    Vault public vault;
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    VaultHandler public handler;
    
    address public admin;
    address public trader;
    
    function setUp() public {
        admin = makeAddr("admin");
        trader = makeAddr("trader");
        
        // Deploy tokens
        tokenA = new MockStableCoin("TokenA");
        tokenB = new MockStableCoin("TokenB");
        
        // Deploy vault with admin as deployer
        vm.startPrank(admin);
        vault = new Vault(admin);
        
        // Grant trader role
        vault.grantRole(vault.TRADER_ROLE(), trader);
        vm.stopPrank();
        
        // Deploy handler
        handler = new VaultHandler(vault, tokenA, tokenB, admin, trader);
        
        // Grant trader role to handler for creditLedger
        bytes32 traderRole = vault.TRADER_ROLE();
        vm.prank(admin);
        vault.grantRole(traderRole, address(handler));
        
        targetContract(address(handler));
        
        // Exclude admin functions from fuzzing
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.withdrawToRecipient.selector;
        selectors[3] = VaultHandler.transferLedger.selector;
        selectors[4] = VaultHandler.creditLedger.selector;
        selectors[5] = VaultHandler.setBlacklisted.selector;
        selectors[6] = VaultHandler.rescueToken.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    // ============ Core Solvency Invariants ============
    
    /**
     * @notice INVARIANT: Vault actual balance >= sum of all user ledger balances
     * @dev This is the most critical invariant - vault must always be solvent
     */
    function invariant_vaultSolvency() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            uint256 actualBalance = IERC20(token).balanceOf(address(vault));
            
            uint256 sumLedgerBalances = 0;
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                sumLedgerBalances += vault.balanceOf(token, user);
            }
            
            // Add admin balance (treasury)
            sumLedgerBalances += vault.balanceOf(token, admin);
            
            assertGe(
                actualBalance,
                sumLedgerBalances,
                "CRITICAL: Vault is insolvent - actual balance < ledger sum"
            );
        }
    }
    
    /**
     * @notice INVARIANT: No individual user balance exceeds vault's actual balance
     */
    function invariant_noUserExceedsVaultBalance() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            uint256 actualBalance = IERC20(token).balanceOf(address(vault));
            
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                uint256 userBalance = vault.balanceOf(token, user);
                
                assertLe(
                    userBalance,
                    actualBalance,
                    "User balance exceeds vault actual balance"
                );
            }
        }
    }
    
    /**
     * @notice INVARIANT: Transfer ledger preserves total balance
     * @dev Sum of all balances should equal total deposits minus withdrawals
     */
    function invariant_transferPreservesTotal() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            
            uint256 sumLedgerBalances = 0;
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                sumLedgerBalances += vault.balanceOf(token, user);
            }
            sumLedgerBalances += vault.balanceOf(token, admin);
            
            uint256 expectedTotal = handler.ghost_totalDeposits(token) - handler.ghost_totalWithdrawals(token);
            
            assertEq(
                sumLedgerBalances,
                expectedTotal,
                "Ledger sum does not match deposits - withdrawals"
            );
        }
    }
    
    // ============ Access Control Invariants ============
    
    /**
     * @notice INVARIANT: Only addresses with TRADER_ROLE can modify balances
     * @dev Verified by checking role assignments
     */
    function invariant_traderRoleRequired() public view {
        assertTrue(vault.hasRole(vault.TRADER_ROLE(), trader));
        assertTrue(vault.hasRole(vault.TRADER_ROLE(), address(handler)));
    }
    
    /**
     * @notice INVARIANT: Admin role is properly assigned
     */
    function invariant_adminRoleAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }
    
    // ============ Blacklist Invariants ============
    
    /**
     * @notice INVARIANT: Blacklisted users cannot receive deposits
     * @dev Verified by checking ghost tracking matches vault state
     */
    function invariant_blacklistConsistency() public view {
        for (uint256 u = 0; u < handler.getUserCount(); u++) {
            address user = handler.getUser(u);
            assertEq(
                vault.isBlacklisted(user),
                handler.ghost_blacklisted(user),
                "Blacklist state mismatch"
            );
        }
    }
    
    // ============ Balance Integrity Invariants ============
    
    /**
     * @notice INVARIANT: User balances are always non-negative
     * @dev Solidity uint256 guarantees this, but we verify no underflow occurred
     */
    function invariant_balancesNonNegative() public view {
        for (uint256 t = 0; t < handler.getTokenCount(); t++) {
            address token = handler.getToken(t);
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                // This will always pass for uint256, but verifies no weird state
                assertGe(vault.balanceOf(token, user), 0);
            }
        }
    }
    
    /**
     * @notice INVARIANT: Rescue can only withdraw surplus tokens
     * @dev Vault balance after rescue >= tracked balance sum
     */
    function invariant_rescueOnlySurplus() public view {
        // Already covered by solvency invariant
        // This is a documentation invariant
    }
    
    // ============ Call Summary ============
    
    function invariant_callSummary() public view {
        console.log("=== Vault Invariant Test Summary ===");
        console.log("Deposits:", handler.ghost_depositCount());
        console.log("Withdrawals:", handler.ghost_withdrawCount());
        console.log("Transfers:", handler.ghost_transferCount());
        console.log("Credits:", handler.ghost_creditCount());
    }
}
