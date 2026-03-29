// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

error InvalidCostAmount();
error MatchExpired();

/**
 * @notice Data structure for a single order
 */
struct Order {
    address user;
    uint48 expiration;
    uint48 feeBps;
    address recipient; // if recipient is address(0), it means the order is for internal ledger swap and the payout is credited to the user in their vault. Otherwise, the payout is sent to the recipient which can be the user or other external wallet.
    address fromToken;
    address toToken;
    uint256 fromAmount;
    uint256 toAmount;
    uint256 initialDepositAmount;
    uint256 uuid;
}

/**
 * @notice Data required to match two orders
 */
struct MatchData {
    Order order0;
    bytes signature0;
    uint256 matchAmount0; // Amount of order0.fromToken to fill
    Order order1;
    bytes signature1;
    uint256 matchAmount1; // Amount of order1.fromToken to fill
}

/**
 * @notice Instant withdraw request signed by user for executor-authorized withdrawal
 * @dev NOTE: Named 'WithdrawIntent' for legacy reasons — this refers to SOR withdrawal request.
 */
struct WithdrawIntent {
    address user;
    address[] tokens;
    uint256[] amounts;
    address recipient;
    uint256 deadline;
    uint256 uuid;
}

/**
 * @notice Bundled parameters for SOR execution (resolves stack depth issues).
 * @dev NOTE: Named 'IntentParams' for legacy reasons — this refers to SOR parameters.
 */
struct IntentParams {
    address inputToken;
    address outputToken;
    uint256 maxInputAmount;
    uint256 minOutputAmount;
    address recipient;
    uint256 initialDepositAmount;
    uint256 uuid;
    uint48 deadline;
}

bytes32 constant ORDER_TYPEHASH = keccak256("Order(address user,uint48 expiration,uint48 feeBps,address recipient,address fromToken,address toToken,uint256 fromAmount,uint256 toAmount,uint256 initialDepositAmount,uint256 uuid)");

// NOTE: Named 'INTENT_TYPEHASH' for legacy reasons — this refers to the SOR parameters type hash.
bytes32 constant INTENT_TYPEHASH = keccak256("Intent(address inputToken,address outputToken,uint256 maxInputAmount,uint256 minOutputAmount,address recipient,uint256 initialDepositAmount,uint256 uuid,uint48 deadline)");

// NOTE: Named 'WITHDRAW_INTENT_TYPEHASH' for legacy reasons — this refers to the SOR withdrawal type hash.
bytes32 constant WITHDRAW_INTENT_TYPEHASH = keccak256("WithdrawIntent(address user,address[] tokens,uint256[] amounts,address recipient,uint256 deadline,uint256 uuid)");

// Basis points denominator (100% = 10000)
uint256 constant BPS_DENOMINATOR = 10000;

/**
 * @title SeraLib
 * @notice A library for pure functions and constants used across the Sera protocol.
 */
library SeraLib {
    function getOrderHashCalldata(Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(ORDER_TYPEHASH, order.user, order.expiration, order.feeBps, order.recipient, order.fromToken, order.toToken, order.fromAmount, order.toAmount, order.initialDepositAmount, order.uuid));
    }

    /**
     * @notice Compute execution values and enforce pricing constraints
     */
    function _executionValues(MatchData calldata _match, uint256 effectiveAmount0, uint256 effectiveAmount1) internal pure returns (uint256 executionValue0, uint256 executionValue1) {
        // amount upper bounds are already validated in `_validateOrderCommon` before this is invoked

        // executionValue0 = Amount of "toToken" (order1.fromToken) that order0 expects for the given effectiveAmount0
        executionValue0 = Math.mulDiv(effectiveAmount0, _match.order0.toAmount, _match.order0.fromAmount, Math.Rounding.Ceil);

        // executionValue1 = Amount of "toToken" (order0.fromToken) that order1 expects for the given effectiveAmount1
        executionValue1 = Math.mulDiv(effectiveAmount1, _match.order1.toAmount, _match.order1.fromAmount, Math.Rounding.Ceil);

        if (effectiveAmount1 < executionValue0 || effectiveAmount0 < executionValue1) revert InvalidCostAmount();
    }

    /// @dev EIP-712 canonical encoding for address[]: contiguous 32-byte words (calldata addresses are naturally padded).
    function hashAddressArray(address[] calldata arr) internal pure returns (bytes32 hash) {
        assembly {
            let len := mul(arr.length, 32)
            let ptr := mload(0x40)
            calldatacopy(ptr, arr.offset, len)
            hash := keccak256(ptr, len)
        }
    }

    /// @dev EIP-712 canonical encoding for uint256[]: contiguous 32-byte words.
    function hashUint256Array(uint256[] calldata arr) internal pure returns (bytes32 hash) {
        assembly {
            let len := mul(arr.length, 32)
            let ptr := mload(0x40)
            calldatacopy(ptr, arr.offset, len)
            hash := keccak256(ptr, len)
        }
    }
}
