// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// SeraAdmin: Admin-only configuration functions extracted from Sera for readability.
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./Vault.sol";
/**
 * @title SeraAdmin
 * @notice Abstract base containing admin-only configuration functions for the Sera protocol.
 *         Inherited by Sera.sol to keep the core matching contract focused on settlement logic.
 * @dev All state variables declared here are shared with the child Sera contract.
 */

abstract contract SeraAdmin is AccessControl, Pausable {
    using SafeERC20 for IERC20;
    // ============ Admin Errors ============

    error InvalidAddress();
    error InvalidAmount();
    error InvalidToken(address token);
    error NoBalance();
    error NoTreasury();
    error TokenNotWhitelisted(address token);
    // ============ Admin State ============
    /// @notice Vault custody contract used for deposits and settlement

    Vault public vault;
    /// @notice Treasury address that receives protocol fees/spread
    address public treasury;

    struct SlippageShare {
        uint64 makerShareBps;
        uint64 takerShareBps;
        uint64 protocolShareBps;
        uint64 totalBps;
    } // The denominator (e.g., 10000)
    /// @notice The percentage split of positive slippage (spread) the protocol captures.
    /// @dev Represented in basis points. The shares must sum exactly to totalBps.

    SlippageShare public slippageShares;

    struct TokenConfig {
        bool isWhitelisted;
        uint248 minAmount;
    }
    /// @notice Token whitelist and minimum order amounts packed into a single storage slot

    mapping(address => TokenConfig) public tokenConfigs;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // ============ Admin Events ============

    event TreasurySet(address indexed treasury);
    event SlippageSharesModified(uint64 makerShare, uint64 takerShare, uint64 protocolShare, uint64 totalBps);
    event WhitelistedTokenModified(address indexed token, bool isWhitelisted, uint256 minAmount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    // ============ Admin Functions ============
    /**
     * @notice Owner sets treasury address for fee/spread capture
     * @param _treasury New treasury address (cannot be zero)
     */

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }
    /**
     * @notice Set the 3-way split percentage of positive slippage
     * @param _makerShare Maker's share
     * @param _takerShare Taker's share
     * @param _protocolShare Protocol's share
     * @param _totalBps The denominator the shares must sum to (e.g., 10000)
     */

    function setSlippageShares(uint64 _makerShare, uint64 _takerShare, uint64 _protocolShare, uint64 _totalBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_totalBps == 0 || _makerShare + _takerShare + _protocolShare != _totalBps) revert InvalidAmount();
        slippageShares = SlippageShare({makerShareBps: _makerShare, takerShareBps: _takerShare, protocolShareBps: _protocolShare, totalBps: _totalBps});
        emit SlippageSharesModified(_makerShare, _takerShare, _protocolShare, _totalBps);
    }
    /**
     * @notice Batch whitelist multiple tokens with individual settings.
     * @param _tokens Array of token addresses
     * @param _isWhitelisted Whether the tokens should be whitelisted
     * @param _minAmounts Array of minimum order amounts (must match _tokens length)
     */

    function batchModifyWhitelistedTokens(address[] calldata _tokens, bool _isWhitelisted, uint256[] calldata _minAmounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = _tokens.length;
        if (len != _minAmounts.length) revert InvalidAmount();
        for (uint256 i = 0; i < len;) {
            _modifyWhitelistedToken(_tokens[i], _isWhitelisted, _minAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }
    /**
     * @notice Internal function to modify a single token's whitelist status.
     */

    function _modifyWhitelistedToken(address _token, bool _isWhitelisted, uint256 _minAmount) internal {
        if (_token == address(0)) revert InvalidAddress();
        if (_minAmount > type(uint248).max) revert InvalidAmount();
        tokenConfigs[_token] = TokenConfig({isWhitelisted: _isWhitelisted, minAmount: uint248(_minAmount)});
        emit WhitelistedTokenModified(_token, _isWhitelisted, _minAmount);
    }
    /// @notice Admin can rescue tokens accidentally sent directly to this contract

    function rescueToken(address _recipient, address _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipient == address(0)) revert InvalidAddress();
        if (_token == address(0)) revert InvalidToken(_token);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NoBalance();
        IERC20(_token).safeTransfer(_recipient, balance);
        emit Rescued(_token, _recipient, balance);
    }
    /// @notice Emergency pause

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }
    /// @notice Resume after pause

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }
}
