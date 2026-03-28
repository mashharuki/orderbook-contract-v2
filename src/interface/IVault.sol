// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// IVault: Interface for the custody layer used by Sera.
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/IAccessControl.sol";

interface IVault is IAccessControl {
    // ============ Custom Errors ============
    error BlacklistedUser(address user);
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error CannotRescueTrackedFunds();
    error InsufficientSurplus();

    // ============ Events ============

    // Emitted when tokens are deposited/credited to a user in the vault.
    event Deposited(address indexed token, address indexed user, uint256 amount);
    // Emitted when tokens are withdrawn from a user balance in the vault.
    event Withdrawn(address indexed token, address indexed user, uint256 amount);
    // Emitted when a user is blacklisted/unblacklisted.
    event Blacklisted(address indexed user, bool isBlacklisted);

    // ============ Functions ============

    // Returns the TRADER_ROLE identifier.
    function TRADER_ROLE() external view returns (bytes32);

    /**
     * @notice Deposit tokens into the vault from the user's external wallet
     * @param user The user to credit
     * @param token The token address
     * @param amount The amount to pull via transferFrom
     */
    function deposit(address user, address token, uint256 amount) external;

    /**
     * @notice Credit tokens to user ledger based on caller-provided amount.
     * @dev CALLER INVARIANT: Caller MUST have already executed safeTransfer(vault, expectedAmount)
     *      in the same transaction before calling this function. No on-chain verification is
     *      performed. Violating this invariant will cause vault insolvency.
     * @param user The user to credit
     * @param token The token address
     * @param expectedAmount The amount to credit (must match prior safeTransfer)
     */
    function creditLedger(address user, address token, uint256 expectedAmount) external;

    // Withdraws tokens to an arbitrary recipient.
    function withdraw(address user, address token, uint256 amount, address to) external;

    // Performs an internal ledger transfer between two users without moving ERC20s.
    function transferLedger(address fromUser, address toUser, address token, uint256 amount) external;

    // Returns a user's vault balance for a token.
    function balanceOf(address token, address user) external view returns (uint256);

    // Returns total assets of a token held by the vault (wrapper for token.balanceOf(this)).
    function balanceOf(address token) external view returns (uint256);

    // Rescue tokens stuck in the vault.
    function rescueToken(address token, address to, uint256 amount) external;

    // Sets blacklist status for a user.
    function setBlacklisted(address user, bool isBlacklisted) external;

    // Returns whether a user is blacklisted.
    function isBlacklisted(address user) external view returns (bool);
}
