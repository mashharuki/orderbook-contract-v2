// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// SeraBatcher: Unified batch matching — best-effort and fill-or-kill modes with swapWithPermit.
pragma solidity 0.8.24;

import "./SeraBase.sol";
/**
 * @title SeraBatcher - Unified Batch Order Matching
 * @notice Combines best-effort (continue-on-error) and FOK (all-or-nothing) batch matching,
 *         plus single-tx swap via EIP-2612 Permit + Deposit + Match.
 */

contract SeraBatcher is SeraBase {
    // ============ Custom Errors ============
    error TooManyOrders();
    error TooManyBatches();
    /// @notice Maximum number of order pairs per batch

    uint256 public constant MAX_BATCH_SIZE = 20;
    // ============ Structs ============

    struct AtomicBatch {
        MatchData[] matches;
    }
    // ============ Events ============

    event MatchFailed(bytes32 indexed orderHash0, bytes32 indexed orderHash1, bytes reason, uint256 indexed batchIndex);
    event BatchExecuted(uint256 attempted, uint256 failedMask);
    event AtomicBatchExecuted(uint256 matchCount);
    event AtomicBatchFailed(uint256 batchIndex, bytes reason);
    /**
     * @notice Initialize with reference to Sera contract
     * @param _sera Address of the core Sera matching engine
     */

    constructor(address _sera) SeraBase(_sera) {}
    /**
     * @notice Batch match multiple order pairs with continue-on-error semantics. Used for bundling a set of independent transactions as there is time lag in between every block. We use this as it's cheaper than multicall3 in gas.
     * @dev Uses try-catch to continue processing even if individual matches fail.
     * @param _matches Array of match instructions (max 20 pairs)
     * @return failedMask Bitmask where bit `i` is 1 if that specific match failed.
     */

    function batchMatchOrders(MatchData[] calldata _matches) external onlySeraRole(EXECUTOR_ROLE_CACHED) whenNotPaused returns (uint256 failedMask) {
        if (_matches.length > MAX_BATCH_SIZE) revert TooManyOrders();
        for (uint256 i = 0; i < _matches.length;) {
            try sera.matchOrders(_matches[i]) {}
            catch (bytes memory lowLevelData) {
                failedMask |= (1 << i);
                bytes32 h0 = SeraLib.getOrderHashCalldata(_matches[i].order0);
                bytes32 h1 = SeraLib.getOrderHashCalldata(_matches[i].order1);
                emit MatchFailed(h0, h1, lowLevelData, i);
            }
            unchecked {
                ++i;
            }
        }
        emit BatchExecuted(_matches.length, failedMask);
    }
    /**
     * @notice Atomically match multiple order pairs, all or nothing. Used for dependent orders which guarantees the order will revert if it fails. We use this as it's cheaper than multicall3 in gas.
     * @dev If ANY match fails, the entire transaction reverts.
     * @param _matches Array of match instructions (max 20 to prevent gas limit issues)
     */

    function batchMatchOrdersAtomic(MatchData[] calldata _matches) external onlySeraRole(EXECUTOR_ROLE_CACHED) whenNotPaused {
        if (_matches.length > MAX_BATCH_SIZE) revert TooManyOrders();
        for (uint256 i = 0; i < _matches.length;) {
            sera.matchOrders(_matches[i]);
            unchecked {
                ++i;
            }
        }
        emit AtomicBatchExecuted(_matches.length);
    }
    /**
     * @notice Execs atomic dependent orders and independent single orders.
     * @dev Uses try/catch on internal atomic loops. If an atomic batch fails, execution continues.
     * @param _atomicBatches Array of AtomicBatch structs (all-or-nothing sub-batches)
     * @param _singleMatches Array of independent MatchData structs (continue-on-error)
     * @return failedMask Bitmask where bit `i` is 1 if that specific atomic batch or single match failed, sequentially. Designed this way so failures can be recognised instantly by reading the return value. If > 0, it means there are failures. By checking the bitmask, we can know which specific atomic batch or single match failed and check the result from the emitted event.
     */

    function batchMatchMixed(AtomicBatch[] calldata _atomicBatches, MatchData[] calldata _singleMatches) external onlySeraRole(EXECUTOR_ROLE_CACHED) whenNotPaused returns (uint256 failedMask) {
        if (_atomicBatches.length > MAX_BATCH_SIZE) revert TooManyBatches();
        if (_singleMatches.length > MAX_BATCH_SIZE) revert TooManyOrders();
        // 1. Process Atomic Sub-Batches
        for (uint256 i = 0; i < _atomicBatches.length;) {
            // NOTE: Uses `this.batchMatchOrdersAtomic()` (external self-call) intentionally
            // to get try/catch revert isolation — Solidity only supports try/catch on external calls.
            // The onlySeraRole check inside re-validates this contract's EXECUTOR_ROLE (not the original caller).
            try this.batchMatchOrdersAtomic(_atomicBatches[i].matches) {}
            catch (bytes memory lowLevelData) {
                failedMask |= (1 << i);
                emit AtomicBatchFailed(i, lowLevelData);
            }
            unchecked {
                ++i;
            }
        }
        // 2. Process Independent Single Orders
        for (uint256 i = 0; i < _singleMatches.length;) {
            try sera.matchOrders(_singleMatches[i]) {}
            catch (bytes memory lowLevelData) {
                failedMask |= (1 << (_atomicBatches.length + i));
                bytes32 h0 = SeraLib.getOrderHashCalldata(_singleMatches[i].order0);
                bytes32 h1 = SeraLib.getOrderHashCalldata(_singleMatches[i].order1);
                emit MatchFailed(h0, h1, lowLevelData, i + _atomicBatches.length);
            }
            unchecked {
                ++i;
            }
        }
    }
    /// @notice Contract version for tracking. New contracts are deployed with incremented version.

    uint256 public constant VERSION = 1;
}
