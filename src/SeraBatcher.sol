// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// SeraBatcher: Unified batch matching — best-effort and fill-or-kill modes, plus SOR intent batching.
pragma solidity 0.8.24;

import "./SeraBase.sol";
import "./SeraSOR.sol";
import {MatchExpired, IntentParams} from "./SeraLib.sol";

/**
 * @title SeraBatcher - Unified Batch Order Matching
 * @notice Combines best-effort (continue-on-error) and FOK (all-or-nothing) batch matching
 *         for standard order pairs, plus try-catch SOR execution.
 * @dev SOR executions are always processed in continue-on-error mode because each SOR order is
 *      independently atomic — there is no dependency between separate SOR orders.
 *      Named 'intents' in some identifiers for legacy reasons — all refer to SOR.
 */
contract SeraBatcher is SeraBase {
    // ============ Custom Errors ============
    error TooManyOrders();
    error TooManyBatches();
    error TooManyIntents(); // NOTE: Refers to SOR executions
    error InvalidSORAddress();

    /// @notice Maximum number of order pairs per batch
    uint256 public constant MAX_BATCH_SIZE = 20;

    /// @notice Maximum number of SOR executions per batch
    /// @dev Named 'MAX_INTENT_SIZE' for legacy reasons — refers to SOR executions.
    uint256 public constant MAX_INTENT_SIZE = 10;

    /// @notice Reference to the SeraSOR contract for SOR execution
    /// @dev Named 'sor' — this is the Smart Order Router.
    SeraSOR public immutable sor;

    // ============ Structs ============
    struct AtomicBatch {
        MatchData[] matches;
    }

    /// @notice Bundled parameters for a single SOR execution
    /// @dev Named 'IntentExecution' for legacy reasons — refers to SOR execution.
    struct IntentExecution {
        MatchData[] matches;
        bytes intentSignature;
        IntentParams intent;
        uint8 uniqueTokenCount;
        uint256 permitDeadline;
        bytes permitSignature;
    }

    // ============ Events ============
    event MatchFailed(bytes32 indexed orderHash0, bytes32 indexed orderHash1, bytes reason, uint256 indexed batchIndex);
    event BatchExecuted(uint256 attempted, uint256 failedMask);
    event AtomicBatchExecuted(uint256 matchCount);
    event AtomicBatchFailed(uint256 batchIndex, bytes reason);
    event IntentFailed(uint256 indexed intentIndex, bytes reason); // NOTE: 'Intent' refers to SOR execution

    /**
     * @notice Initialize with reference to Sera and SeraSOR contracts
     * @param _sera Address of the core Sera matching engine
     * @param _sor Address of the SeraSOR router
     */
    constructor(address _sera, address _sor) SeraBase(_sera) {
        if (_sor == address(0)) revert InvalidSORAddress();
        sor = SeraSOR(_sor);
    }

    /**
     * @notice Batch match multiple order pairs with continue-on-error semantics. Used for bundling a set of independent transactions as there is time lag in between every block. We use this as it's cheaper than multicall3 in gas.
     * @dev Uses try-catch to continue processing even if individual matches fail.
     * @param _matches Array of match instructions (max 20 pairs)
     * @return failedMask Bitmask where bit `i` is 1 if that specific match failed.
     */
    function batchMatchOrders(MatchData[] calldata _matches, uint256 deadline)
        external
        onlySeraRole(EXECUTOR_ROLE_CACHED)
        whenNotPaused
        returns (uint256 failedMask)
    {
        if (block.timestamp > deadline) revert MatchExpired();
        if (_matches.length > MAX_BATCH_SIZE) revert TooManyOrders();

        for (uint256 i = 0; i < _matches.length;) {
            try sera.matchOrders(_matches[i], deadline) {
                // Success - nothing to do
            } catch (bytes memory lowLevelData) {
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
    function batchMatchOrdersAtomic(MatchData[] calldata _matches, uint256 deadline)
        external
        onlySeraRole(EXECUTOR_ROLE_CACHED)
        whenNotPaused
    {
        if (block.timestamp > deadline) revert MatchExpired();
        if (_matches.length > MAX_BATCH_SIZE) revert TooManyOrders();

        for (uint256 i = 0; i < _matches.length;) {
            sera.matchOrders(_matches[i], deadline);
            unchecked {
                ++i;
            }
        }

        emit AtomicBatchExecuted(_matches.length);
    }

    /**
     * @notice Execs atomic dependent orders, independent single orders, and SOR intents in one tx.
     * @dev Uses try/catch on internal atomic loops and SOR intents. If any sub-operation fails, execution continues.
     *      SOR intents are always try-catch because each intent is independently atomic — no inter-intent dependencies.
     * @param _atomicBatches Array of AtomicBatch structs (all-or-nothing sub-batches)
     * @param _singleMatches Array of independent MatchData structs (continue-on-error)
     * @param _intents Array of SOR executions (continue-on-error, max 10). Named 'intents' for legacy reasons.
     * @return failedMask Bitmask where bit `i` is 1 if that specific atomic batch, single match, or SOR execution failed, sequentially.
     */
    function batchMatchMixed(
        AtomicBatch[] calldata _atomicBatches,
        MatchData[] calldata _singleMatches,
        IntentExecution[] calldata _intents,
        uint256 deadline
    )
        external
        onlySeraRole(EXECUTOR_ROLE_CACHED)
        whenNotPaused
        returns (uint256 failedMask)
    {
        if (block.timestamp > deadline) revert MatchExpired();
        if (_atomicBatches.length > MAX_BATCH_SIZE) revert TooManyBatches();
        if (_singleMatches.length > MAX_BATCH_SIZE) revert TooManyOrders();
        if (_intents.length > MAX_INTENT_SIZE) revert TooManyIntents();

        // 1. Process Atomic Sub-Batches
        for (uint256 i = 0; i < _atomicBatches.length;) {
            // NOTE: Uses `this.batchMatchOrdersAtomic()` (external self-call) intentionally
            // to get try/catch revert isolation — Solidity only supports try/catch on external calls.
            // The onlySeraRole check inside re-validates this contract's EXECUTOR_ROLE (not the original caller).
            try this.batchMatchOrdersAtomic(_atomicBatches[i].matches, deadline) {
                // Success - nothing to do
            } catch (bytes memory lowLevelData) {
                failedMask |= (1 << i);
                emit AtomicBatchFailed(i, lowLevelData);
            }
            unchecked {
                ++i;
            }
        }

        // 2. Process Independent Single Orders
        for (uint256 i = 0; i < _singleMatches.length;) {
            try sera.matchOrders(_singleMatches[i], deadline) {
                // Success - nothing to do
            } catch (bytes memory lowLevelData) {
                failedMask |= (1 << (_atomicBatches.length + i));
                bytes32 h0 = SeraLib.getOrderHashCalldata(_singleMatches[i].order0);
                bytes32 h1 = SeraLib.getOrderHashCalldata(_singleMatches[i].order1);
                emit MatchFailed(h0, h1, lowLevelData, i + _atomicBatches.length);
            }
            unchecked {
                ++i;
            }
        }

        // 3. Process SOR Executions (always try-catch — each SOR order is independently atomic)
        uint256 intentOffset = _atomicBatches.length + _singleMatches.length;
        for (uint256 i = 0; i < _intents.length;) {
            IntentExecution calldata ie = _intents[i];
            try sor.executeIntent(
                ie.matches,
                ie.intentSignature,
                ie.intent,
                ie.uniqueTokenCount,
                ie.permitDeadline,
                ie.permitSignature
            ) {
                // Success
            } catch (bytes memory lowLevelData) {
                failedMask |= (1 << (intentOffset + i));
                emit IntentFailed(i, lowLevelData);
            }
            unchecked {
                ++i;
            }
        }

		uint256 attempted = _atomicBatches.length + _singleMatches.length + _intents.length;
        emit BatchExecuted(attempted, failedMask);
    }

    /// @notice Contract version for tracking. New contracts are deployed with incremented version.
    uint256 public constant VERSION = 2;
}
