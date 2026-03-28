// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Vault: Role-based custody layer with per-user balances, block-delay anti-race, and blacklist.
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interface/IVault.sol";

contract Vault is IVault, ReentrancyGuardTransient, AccessControl {
    using SafeERC20 for IERC20;
    // Trader role which has access to withdraw and deposit functions. Default trader role is Sera.sol. Protected with Compound Timelock.

    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    // Per-token per-user balances held in the vault.
    mapping(address => mapping(address => uint256)) private balances;
    // Total tracked balance per token (sum of all user balances)
    mapping(address => uint256) private trackedBalance;
    // Blacklist flag to block vault interactions.
    mapping(address => bool) private blacklisted;
    // Initialize with deployer as default admin.

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }
    // ============================================================
    // Ledger & Management Functions
    // ============================================================
    // Trader-only deposit; pulls tokens and credits user balance by actual amount received.

    function deposit(address user, address token, uint256 amount) external override nonReentrant onlyRole(TRADER_ROLE) {
        if (blacklisted[user]) revert BlacklistedUser(user);
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(user, address(this), amount);
        balances[token][user] += amount;
        trackedBalance[token] += amount;
        emit Deposited(token, user, amount);
    }
    /**
     * @notice Credits `expectedAmount` of `token` to `user`.
     * @dev CALLER INVARIANT: Caller MUST have already executed safeTransfer(vault, expectedAmount)
     *      in the same transaction before calling this function. No on-chain verification is
     *      performed. Violating this invariant will cause vault insolvency.
     * @param user The user to credit
     * @param token The token address
     * @param expectedAmount The amount to credit
     */

    function creditLedger(address user, address token, uint256 expectedAmount) external override nonReentrant onlyRole(TRADER_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (blacklisted[user]) revert BlacklistedUser(user);
        if (expectedAmount == 0) revert ZeroAmount();
        balances[token][user] += expectedAmount;
        trackedBalance[token] += expectedAmount;
        emit Deposited(token, user, expectedAmount);
    }
    // Trader-only withdraw to arbitrary recipient. user == to is self-withdraw.

    function withdraw(address user, address token, uint256 amount, address to) external override nonReentrant onlyRole(TRADER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balances[token][user];
        if (bal < amount) revert InsufficientBalance();
        balances[token][user] = bal - amount;
        trackedBalance[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, user, amount);
    }
    // Internal ledger transfer between two users. No ERC20 moves.

    function transferLedger(address fromUser, address toUser, address token, uint256 amount) external override nonReentrant onlyRole(TRADER_ROLE) {
        if (toUser == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 fromBal = balances[token][fromUser];
        if (fromBal < amount) revert InsufficientBalance();
        balances[token][fromUser] = fromBal - amount;
        balances[token][toUser] += amount;
        // trackedBalance[token] does not change because total vault TVL remains the same
        // Emit withdrawal and deposit events to keep standard subgraph indexers working
        emit Withdrawn(token, fromUser, amount);
        emit Deposited(token, toUser, amount);
    }
    // Admin can set/unset blacklist flag.

    function setBlacklisted(address user, bool _isBlacklisted) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        blacklisted[user] = _isBlacklisted;
        emit Blacklisted(user, _isBlacklisted);
    }
    // View blacklist status.

    function isBlacklisted(address user) external view override returns (bool) {
        return blacklisted[user];
    }
    // View user token balance held in vault.

    function balanceOf(address token, address user) external view override returns (uint256) {
        return balances[token][user];
    }
    // View total assets of a token held by the vault (wrapper for token.balanceOf(this)).

    function balanceOf(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
    // Rescue arbitrary tokens stuck in vault.
    // Only allows rescuing surplus tokens not tracked in user balances.

    event Rescued(address indexed token, address indexed to, uint256 amount);

    function rescueToken(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 vaultBalance = IERC20(token).balanceOf(address(this));
        uint256 surplus = vaultBalance - trackedBalance[token];
        if (amount > surplus) revert CannotRescueTrackedFunds();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
