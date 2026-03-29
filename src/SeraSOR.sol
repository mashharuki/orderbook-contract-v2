// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// SeraSOR: Smart Order Router for multi-leg atomic route matching with transient balance optimization.
pragma solidity 0.8.24;

import {ECDSA as SoladyECDSA} from "solady/src/utils/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./Sera.sol";
import "./SeraBase.sol";
import {MatchExpired, IntentParams} from "./SeraLib.sol";

/**
 * @title SeraSOR - Smart Order Router
 * @notice Orchestrates multi-leg atomic routes with:
 *         - SOR-based signing: taker commits to (inputToken, outputToken, maxInput, minOutput)
 *         - Executor picks the optimal route at execution time (fixes TOCTOU)
 *         - Transient balance optimization (intermediate tokens skip vault)
 *         - Single EIP-712 signature for the SOR order (better UX)
 * @dev Named 'Intent-Based' in legacy references — all 'intent' identifiers refer to SOR.
 *      Extends SeraBase, delegates settlement to Sera.settleRoutedLeg().
 *      No direct Vault access — all token operations go through Sera.
 */
contract SeraSOR is SeraBase {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    error EmptyRoute();
    error TooManyLegs();
    error InvalidRoute();
    error TransientBalanceNotZero(address token, uint256 amount);
    error InsufficientOutput();
    error ExcessiveInput();
    error IntentAlreadyUsed(); // NOTE: Refers to SOR execution replay protection

    // ============ Events ============
    event IntentMatched(bytes32 indexed intentHash, address indexed taker, uint256 legCount); // NOTE: 'intent' refers to SOR execution
    event IntentLegMatched(bytes32 indexed intentHash, uint256 indexed legIndex, bytes32 takerOrderHash, bytes32 makerOrderHash); // NOTE: 'intent' refers to SOR execution

    /// @notice Upper bound to protect against pathological gas usage
    uint256 public constant MAX_ROUTE_LEGS = 20;

    /// @notice Tracks used SOR UUIDs per user for replay protection
    /// @dev Named 'isIntentUuidUsed' for legacy reasons — refers to SOR execution replay protection.
    mapping(address => mapping(uint256 => bool)) public isIntentUuidUsed;

    constructor(address _sera) SeraBase(_sera) {}

    /**
     * @notice Execute a multi-leg atomic route based on a taker's signed SOR order.
     * @dev The taker signs an SOR order covering (inputToken, outputToken, maxInput, minOutput,
     *      recipient, initialDepositAmount, uuid, deadline) bundled as IntentParams (SOR parameters).
     *      The executor constructs the route legs freely, selecting optimal intermediaries.
     *
     * @param matches Array of match data (order0 = taker leg, order1 = maker in each leg)
     * @param intentSignature Single EIP-712 signature from the taker over the SOR order
     * @param intent Signed SOR parameters (see IntentParams struct in SeraLib.sol)
     * @param uniqueTokenCount Hint for transient balance hash table sizing
     */
    function executeIntent(MatchData[] calldata matches, bytes calldata intentSignature, IntentParams calldata intent, uint8 uniqueTokenCount, uint256 permitDeadline, bytes calldata permitSignature) external onlySeraRole(EXECUTOR_ROLE_CACHED) whenNotPaused {
        if (block.timestamp > intent.deadline) revert MatchExpired();
        if (matches.length == 0) revert EmptyRoute();
        if (matches.length > MAX_ROUTE_LEGS) revert TooManyLegs();

        // 1. Compute SOR hash and validate taker signature
        address takerUser = _validateAndConsumeIntent(intentSignature, intent);

        // 2. Transient balance tracking for intermediate tokens
        // It maps token > amount fully in memory keeping it extremely affordable
        // We don't use transient storage due to gas cost. This is the cheapest way.
        uint256 tableSize = uint256(uniqueTokenCount) * 2 + 1;
        address[] memory transientTokens = new address[](tableSize);
        uint256[] memory transientAmounts = new uint256[](tableSize);

        // takerInputCost: total taker spend in inputToken (wallet deposit + vault pulls)
        // Exact wallet pull amount is committed in the intent signature — executor cannot modify
        uint256 takerInputCost = intent.initialDepositAmount;

        // Verify the executor-supplied order matches the signed deposit amount
        if (matches[0].order0.initialDepositAmount != intent.initialDepositAmount) revert InvalidRoute();

        // Taker cannot deposit more from wallet than the first leg requires
        if (takerInputCost > matches[0].matchAmount0) revert ExcessiveInput();

        if (takerInputCost > 0) {
            if (permitSignature.length > 0) _executePermit(intent.inputToken, takerUser, address(this), takerInputCost, permitDeadline, permitSignature);
            // Pull directly from the taker's wallet to the Sera matching engine
            IERC20(intent.inputToken).safeTransferFrom(takerUser, address(sera), takerInputCost);
            _addTransientBalance(transientTokens, transientAmounts, tableSize, intent.inputToken, takerInputCost);
        }

        // 3. Execute each leg
        bytes32 intentHash = _computeIntentHash(intent); // NOTE: 'intentHash' refers to SOR hash
        uint256 totalTakerOutput = 0;

        for (uint256 i = 0; i < matches.length;) {
            MatchData calldata m = matches[i];

            // Enforce: all taker orders belong to same user
            if (m.order0.user != takerUser) revert InvalidRoute();

            // Resolve effective fill amount (sentinel = consume all transient)
            (uint256 effectiveAmount0, uint256 takerVaultPull) = _consumeTransientBalance(transientTokens, transientAmounts, tableSize, m.order0.fromToken, m.matchAmount0);

            // Only the intent's input token may be pulled from the taker's vault.
            // Intermediate legs MUST be fully covered by transient balances.
            if (takerVaultPull > 0 && m.order0.fromToken != intent.inputToken) revert InvalidRoute();
            takerInputCost += takerVaultPull;

            // If this is not the last leg, and the taker's recipient is Sera, then we hold the taker's output for the next leg.
            bool holdTakerOutput = (m.order0.recipient == address(sera));

            // The final leg must always deliver to the signed recipient — never hold inside Sera
            if (holdTakerOutput && i == matches.length - 1) revert InvalidRoute();

            // Settle via Sera — pass effectiveAmount0 so sentinel MUST NOT reach Sera
            (uint256 takerReceives, bytes32 takerHash, bytes32 makerHash) = sera.settleRoutedLeg(m, takerVaultPull, holdTakerOutput, effectiveAmount0);

            // If we hold the taker's output of this leg, we add it to the transient balance for the next leg.
            if (holdTakerOutput && takerReceives > 0) _addTransientBalance(transientTokens, transientAmounts, tableSize, m.order1.fromToken, takerReceives);

            // Track aggregate taker output (terminal legs only)
            // Enforce: every terminal leg's recipient must match the signed intent recipient (diamond-safe)
            if (!holdTakerOutput) {
                if (m.order0.toToken != intent.outputToken) revert InvalidRoute();
                if (m.order0.recipient != intent.recipient) revert InvalidRoute();
                totalTakerOutput += takerReceives;
            }

            // Emit per-leg event
            emit IntentLegMatched(intentHash, i, takerHash, makerHash);

            unchecked {
                ++i;
            }
        }

        // Envelope guards
        if (intent.maxInputAmount > 0 && takerInputCost > intent.maxInputAmount) revert ExcessiveInput();
        if (intent.minOutputAmount > 0 && totalTakerOutput < intent.minOutputAmount) revert InsufficientOutput();

        // 4. Enforce transient zero-balance (skip for single-leg routes — no intermediates)
        //    Any leftover indicates a broken route (misconfigured legs or sentinel not used).
        //    If tokens are accidentally stuck in Sera, admin can recover via SeraAdmin.rescueToken().
        if (matches.length > 1) {
            for (uint256 i = 0; i < tableSize;) {
                if (transientTokens[i] != address(0) && transientAmounts[i] > 0) revert TransientBalanceNotZero(transientTokens[i], transientAmounts[i]);
                unchecked {
                    ++i;
                }
            }
        }

        emit IntentMatched(intentHash, takerUser, matches.length);
    }

    // ============ Internal Functions ============

    /**
     * @notice Compute SOR hash from SOR parameters.
     * @dev Named '_computeIntentHash' for legacy reasons — refers to SOR hash computation.
     */
    function _computeIntentHash(IntentParams calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, p.inputToken, p.outputToken, p.maxInputAmount, p.minOutputAmount, p.recipient, p.initialDepositAmount, p.uuid, p.deadline));
    }

    /**
     * @notice Validate SOR signature, consume the SOR order (replay protection), and return the taker address.
     * @dev Named '_validateAndConsumeIntent' for legacy reasons — refers to SOR validation.
     */
    function _validateAndConsumeIntent(bytes calldata signature, IntentParams calldata p) internal returns (address takerUser) {
        // Validate EIP-712 signature
        bytes32 digest = sera.getIntentDigest(p.inputToken, p.outputToken, p.maxInputAmount, p.minOutputAmount, p.recipient, p.initialDepositAmount, p.uuid, p.deadline);
        takerUser = SoladyECDSA.recover(digest, signature);
        if (takerUser == address(0)) revert Sera.InvalidSignature();

        // Per-user replay protection: each uuid can only execute once per user
        if (isIntentUuidUsed[takerUser][p.uuid]) revert IntentAlreadyUsed();
        isIntentUuidUsed[takerUser][p.uuid] = true;
    }

    function _consumeTransientBalance(address[] memory tokens, uint256[] memory amounts, uint256 tableSize, address token, uint256 requested) internal pure returns (uint256 effectiveAmount, uint256 remaining) {
        uint256 idx = _findTokenSlot(tokens, tableSize, token);

        if (tokens[idx] != token) {
            // No transient — full amount from vault
            if (requested == type(uint256).max) revert InvalidRoute();
            return (requested, requested);
        }

        uint256 available = amounts[idx];

        // Sentinel: consume all available transient
        if (requested == type(uint256).max) {
            if (available == 0) revert InvalidRoute();
            amounts[idx] = 0;
            return (available, 0);
        }

        // Normal: consume up to available
        uint256 used = available < requested ? available : requested;
        amounts[idx] = available - used;
        return (requested, requested - used);
    }

    function _addTransientBalance(address[] memory tokens, uint256[] memory amounts, uint256 tableSize, address token, uint256 amount) internal pure {
        uint256 idx = _findTokenSlot(tokens, tableSize, token);
        if (tokens[idx] == address(0)) tokens[idx] = token;
        amounts[idx] += amount;
    }

    /// @dev INVARIANT: tableSize = (uniqueTokenCount * 2) + 1, guaranteeing >50% empty slots.
    ///      This ensures the open-addressing probe always terminates (an empty slot is always reachable).
    function _findTokenSlot(address[] memory tokens, uint256 tableSize, address token) internal pure returns (uint256 idx) {
        idx = uint256(uint160(token)) % tableSize;
        for (uint256 attempts = 0; attempts < tableSize; attempts++) {
            address cur = tokens[idx];
            if (cur == address(0) || cur == token) return idx;
            unchecked {
                idx++;
                if (idx == tableSize) idx = 0;
            }
        }
        // Should never reach here due to >50% empty slots invariant
        revert InvalidRoute();
    }

    /**
     * @notice Handle EIP-2612 permit silently to allow front-run protection
     * @dev Similar to Uniswap/Sera logic, if the signature is compact, it recovers differently.
     */
    function _executePermit(address token, address owner, address spender, uint256 amount, uint256 deadline, bytes calldata signature) internal {
        uint8 v;
        bytes32 r;
        bytes32 s;
        if (signature.length == 65) {
            assembly {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 0x20))
                v := byte(0, calldataload(add(signature.offset, 0x40)))
            }
        } else if (signature.length == 64) {
            assembly {
                let vs := calldataload(add(signature.offset, 0x20))
                r := calldataload(signature.offset)
                s := and(vs, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
                v := add(shr(255, vs), 27)
            }
        } else {
            revert Sera.InvalidSignatureLength();
        }

        try IERC20Permit(token).permit(owner, spender, amount, deadline, v, r, s) {} catch {}
    }
}
