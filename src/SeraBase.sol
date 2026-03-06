// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "./Sera.sol";
/**
 * @title SeraBase
 * @notice Abstract base contract for Sera extensions sharing access control and pause logic
 */

abstract contract SeraBase {
    error InvalidSeraAddress();
    error Unauthorized(address caller, bytes32 role);
    error SeraPaused();

    Sera public immutable sera;
    /// @notice Cached EXECUTOR_ROLE to avoid cross-contract STATICCALL on every wrapper entry
    bytes32 public immutable EXECUTOR_ROLE_CACHED;

    event Initialized(address indexed sera);

    modifier onlySeraRole(bytes32 role) {
        if (!sera.hasRole(role, msg.sender)) revert Unauthorized(msg.sender, role);
        _;
    }

    modifier whenNotPaused() {
        if (sera.paused()) revert SeraPaused();
        _;
    }

    constructor(address _sera) {
        if (_sera == address(0)) revert InvalidSeraAddress();
        sera = Sera(_sera);
        EXECUTOR_ROLE_CACHED = sera.EXECUTOR_ROLE();
        emit Initialized(_sera);
    }
}
