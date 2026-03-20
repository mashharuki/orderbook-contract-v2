// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// SeraSOR: Smart Order Router for multi-leg atomic route matching with transient balance optimization.
pragma solidity 0.8.24;

import {ECDSA as SoladyECDSA} from "solady/src/utils/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Sera.sol";
import "./SeraBase.sol";
import {MatchExpired} from "./SeraLib.sol";
/**
 * @title SeraSOR - Smart Order Router
 * @notice Orchestrates multi-leg atomic routes with:
 *         - Route binding via routeHash (prevents subset submission)
 *         - Single EIP-712 signature for entire route (better UX)
 *         - Transient balance optimization (intermediate tokens skip vault)
 * @dev Extends SeraBase, delegates settlement to Sera.settleRoutedLeg().
 *      No direct Vault access — all token operations go through Sera.
 */

contract SeraSOR is SeraBase {
    using SafeERC20 for IERC20;
    // ============ Custom Errors ============

    error EmptyRoute();
    error TooManyLegs();
    error InvalidRoute();
    error InvalidRouteHash();
    // ORDER_TYPEHASH is imported from SeraLib.sol globally via Sera.sol
    // ============ Events ============

    event RouteMatched(bytes32 indexed routeHash, address indexed taker, uint256 legCount);
    event RouteLegMatched(bytes32 indexed routeHash, uint256 indexed legIndex, bytes32 takerOrderHash, bytes32 makerOrderHash);
    /// @notice Upper bound to protect against pathological gas usage

    uint256 public constant MAX_ROUTE_LEGS = 20;

    constructor(address _sera) SeraBase(_sera) {}
    /**
     * @notice Execute a multi-leg atomic route with a single taker signature.
     * @dev Unified entry point for all SOR operations:
     *      - initialDepositAmount = 0: Taker funds are pulled from the Vault (pre-deposited).
     *      - initialDepositAmount > 0: Taker MUST approve SeraSOR; tokens are pulled
     *        directly from the taker's wallet into Sera for settlement.
     *      The taker's `recipient` field on the final leg controls where output lands:
     *      - recipient = address(0): credited to the taker's Vault ledger.
     *      - recipient = any address: sent directly to that wallet.
     * @param matches Array of match data (order0 = taker, order1 = maker in each leg)
     * @param routeSignature Single EIP-712 signature from the taker over the route hash
     */

    function executeRoute(MatchData[] calldata matches, bytes calldata routeSignature, uint256 deadline) external onlySeraRole(EXECUTOR_ROLE_CACHED) whenNotPaused {
        if (block.timestamp > deadline) revert MatchExpired();
        if (matches.length == 0) revert EmptyRoute();
        if (matches.length > MAX_ROUTE_LEGS) revert TooManyLegs();
        // 1. Compute expected route hash from full taker order structs
        bytes32 expectedRouteHash = _computeRouteHash(matches);
        // 2. Validate single taker signature over the route hash
        address takerUser = matches[0].order0.user;
        _validateRouteSignature(takerUser, expectedRouteHash, routeSignature);
        // 3. Transient balance tracking for intermediate tokens
        //    Uses an in-memory hash table for expected O(1) lookup/update. Cheapest in terms of gas, but definitely more work for auditors.
        // This hash table results in the creation of the helper function of _findTokenSlot mimics the behaviour of a mapping.
        uint256 tableSize = (matches.length * 2) + 1;
        address[] memory transientTokens = new address[](tableSize);
        uint256[] memory transientAmounts = new uint256[](tableSize);
        uint256 initialDepositAmount = matches[0].order0.initialDepositAmount;
        if (initialDepositAmount > 0) {
            address inputToken = matches[0].order0.fromToken;
            // Pull directly from the taker's wallet to the Sera matching engine
            IERC20(inputToken).safeTransferFrom(takerUser, address(sera), initialDepositAmount);
            _addTransientBalance(transientTokens, transientAmounts, tableSize, inputToken, initialDepositAmount);
        }
        // 4. Execute each leg
        for (uint256 i = 0; i < matches.length;) {
            MatchData calldata m = matches[i];
            // Enforce: all taker orders belong to same user
            if (m.order0.user != takerUser) revert InvalidRoute();
            // Enforce: taker order is bound to this specific route
            if (m.order0.routeHash != expectedRouteHash) revert InvalidRouteHash();
            // Enforce: maker order is standalone (not part of any route)
            if (m.order1.routeHash != bytes32(0)) revert InvalidRouteHash();
            // Calculate how much to pull from vault vs transient
            uint256 takerVaultPull = _consumeTransientBalance(transientTokens, transientAmounts, tableSize, m.order0.fromToken, m.matchAmount0);
            // Determine if this is an intermediate hop (hold output for next leg)
            bool isLastLeg = (i == matches.length - 1);
            // Enforce: last leg must deliver output to taker, not hold in Sera
            // We allow intermediate legs to hold (for routing) or deliver (for split routing)
            if (isLastLeg && m.order0.recipient == address(sera)) revert InvalidRoute();
            bool holdTakerOutput = !isLastLeg && (m.order0.recipient == address(sera));
            // Settle via Sera (handles vault, fees, distribution)
            (uint256 takerReceives, bytes32 takerHash, bytes32 makerHash) = sera.settleRoutedLeg(m, takerVaultPull, holdTakerOutput);
            // Track transient balance from held output
            if (holdTakerOutput && takerReceives > 0) _addTransientBalance(transientTokens, transientAmounts, tableSize, m.order1.fromToken, takerReceives);
            // Emit per-leg event
            emit RouteLegMatched(expectedRouteHash, i, takerHash, makerHash);
            unchecked {
                ++i;
            }
        }
        // 5. Enforce transient zero-balance
        //    Any leftover indicates a broken route (rounding dust, misconfigured legs) or positive slippage.
        //    Tokens held in Sera cannot be recovered automatically, so we sweep them to the protocol treasury.
        for (uint256 i = 0; i < tableSize;) {
            if (transientTokens[i] != address(0) && transientAmounts[i] > 0) sera.sweepTransientToProtocol(transientTokens[i], transientAmounts[i]);
            unchecked {
                ++i;
            }
        }
        emit RouteMatched(expectedRouteHash, takerUser, matches.length);
    }
    // ============ Internal Functions ============
    /**
     * @notice Compute route hash from all taker orders in the matches array.
     * @dev Hashes the full ORDER_TYPEHASH of each taker order (with routeHash=0)
     *      to ensure the route signature commits to all trade parameters.
     */

    function _computeRouteHash(MatchData[] calldata matches) public pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](matches.length);
        for (uint256 i = 0; i < matches.length;) {
            Order calldata order = matches[i].order0;
            // Recompute the order struct hash with routeHash = bytes32(0) to prevent circular dependency during signing.
            hashes[i] = keccak256(abi.encode(ORDER_TYPEHASH, order.user, order.expiration, order.feeBps, order.recipient, order.fromToken, order.toToken, order.fromAmount, order.toAmount, order.initialDepositAmount, bytes32(0), order.uuid));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }
    /**
     * @notice Validate EIP-712 route signature from the taker.
     */

    function _validateRouteSignature(address signer, bytes32 routeHash, bytes calldata signature) public view {
        bytes32 digest = sera.getRouteDigest(routeHash);
        address recovered = SoladyECDSA.recover(digest, signature);
        if (recovered == address(0) || recovered != signer) revert Sera.InvalidSignature();
    }

    function _consumeTransientBalance(address[] memory tokens, uint256[] memory amounts, uint256 tableSize, address token, uint256 requested) public pure returns (uint256 remaining) {
        remaining = requested;
        uint256 idx = _findTokenSlot(tokens, tableSize, token);
        if (tokens[idx] != token) return remaining;
        uint256 available = amounts[idx];
        if (available == 0) return remaining;
        uint256 used = available < remaining ? available : remaining;
        amounts[idx] = available - used;
        remaining -= used;
    }

    function _addTransientBalance(address[] memory tokens, uint256[] memory amounts, uint256 tableSize, address token, uint256 amount) public pure {
        uint256 idx = _findTokenSlot(tokens, tableSize, token);
        if (tokens[idx] == address(0)) tokens[idx] = token;
        amounts[idx] += amount;
    }
    /// @dev INVARIANT: tableSize = (matches.length * 2) + 1, guaranteeing >50% empty slots.
    ///      This ensures the open-addressing probe always terminates (an empty slot is always reachable).

    function _findTokenSlot(address[] memory tokens, uint256 tableSize, address token) public pure returns (uint256 idx) {
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
}
