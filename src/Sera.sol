// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Sera: Signed limit order matching with vault custody, fee capture, whitelists, and blacklist controls.
pragma solidity 0.8.24;

import {EIP712} from "solady/src/utils/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interface/IVault.sol";
import "./SeraAdmin.sol";
import {
    SeraLib,
    MatchExpired,
    Order,
    MatchData,
    WithdrawIntent,
    InvalidCostAmount,
    ORDER_TYPEHASH,
    INTENT_TYPEHASH,
    WITHDRAW_INTENT_TYPEHASH,
    BPS_DENOMINATOR
} from "./SeraLib.sol";

/**
 * @title Sera - Orderbook DEX with Vault Custody
 * @notice This contract implements a signed order matching system with:
 *         - Vault custody for maker orders
 *         - EIP-712 signatures for all user actions
 *         - Dual-authorization withdrawals (delayed + instant)
 *         - Dynamic fee structure per order
 *         - Ghost liquidity prevention via vault balance checks
 * @dev Inherits from SeraAdmin for admin functions (setTreasury, modifyWhitelistedToken, pause, etc.).
 */
contract Sera is EIP712, SeraAdmin, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    error UserFrozen(address user);
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error WithdrawNotReady();
    error AmountMismatch();
    error IntentExpired(); // NOTE: Refers to SOR request expiration
    error UuidAlreadyUsed();
    error LengthMismatch();
    error InvalidTokenCount();
    error InvalidSignatureLength();
    error InvalidSignature();
    error TokenMismatch();
    error InsufficientVaultBalance();
    error OrderExpired();
    error OrderFilledAmountExceeded();
    error WithdrawExpired();
    error WithdrawInsufficientBalance();
    error UnauthorizedDepositCaller();
    error RouterNotTrusted();
    error OrderExpirationTooLong();
    error InvalidFee();
    error SelfMatch();
    error SameTokenMatch();

    string public constant NAME = "Sera";
    string public constant VERSION = "1";

    /// @notice Withdrawal request tracking
    /// @dev Not packed to a single uint256 because it's rarely used and squeezing uint256 into uint192 may raise weird issues that is not worth the extremely low extra gas
    struct WithdrawRequest {
        uint256 requestBlock;
        uint256 amount;
    }

    /// @notice Withdrawal delay (blocks) for user-initiated vault withdrawals. Set at 7200 for 24hrs
    uint32 public constant WITHDRAW_DELAY_BLOCKS = 7200;

    /// @notice Maximum blocks a delayed withdrawal remains valid after the requestBlock (48hrs)
    uint32 public constant WITHDRAW_EXPIRATION_BLOCKS = 14400;

    /// @notice Maximum allowed remaining lifetime at first execution (1 year from block.timestamp, not from signing)
    uint256 public constant MAX_EXPIRATION = 365 days;

    /// @notice Track filled amount for order hashes to support partial fills
    mapping(bytes32 => uint256) public filledAmount;
    /// @notice SOR replay protection using struct uuid nonce per user
    /// @dev Cannot use hash to protect against uuid replay attacks. Named 'isUuidExecuted' — refers to SOR withdrawal execution.
    mapping(address => mapping(uint256 => bool)) public isUuidExecuted;

    /// @notice SOR intent replay protection, centralized in Sera so all routers share one registry
    /// @dev Moved from SeraSOR to prevent cross-router replay when multiple routers share the same Sera instance (SFO-17).
    mapping(address => mapping(uint256 => bool)) public isIntentUuidUsed;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Withdrawal request tracking - stores block and amount per token per user
    mapping(address => mapping(address => WithdrawRequest)) public withdrawRequests;

    /// @notice Single trusted router contract allowed to call settleRoutedLeg
    /// @dev It is granted special privileges to bypass the Taker's signature verification for individual legs of a multi-hop trade, because the contract itself guarantees the math works out safely. In this case, it is SeraSOR.
    address public trustedRouter;

    event OrderMatched(
        bytes32 indexed orderHash0,
        address indexed user0,
        address token0,
        uint256 amount0,
        uint256 protocolTake0,
        bytes32 indexed orderHash1,
        address user1,
        address token1,
        uint256 amount1,
        uint256 protocolTake1
    );
    event UserFrozenStateChanged(bool frozen, address indexed user);
    event OrderFullyFilled(bytes32 indexed orderHash, address indexed user);
    event ExecutorSet(bool isActive, address indexed executor);
    event WithdrawRequested(address indexed user, address indexed token, uint256 amount, uint256 indexed requestBlock);
    event InstantWithdraw(
        address indexed user, uint256 indexed uuid, address indexed token, uint256 amount, address recipient
    );

    event Withdraw(address indexed token, address indexed to, uint256 amount);
    event TrustedRouterSet(address indexed router);

    /// @notice Initialize with owner and pre-deployed Vault, and set treasury
    constructor(address initialOwner, Vault _vault) {
        if (initialOwner == address(0)) revert InvalidAddress();
        if (address(_vault) == address(0)) revert InvalidAddress();

        // Grant initial roles to the deployer/owner
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(EXECUTOR_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);

        vault = _vault;

        treasury = initialOwner;
        slippageShares = SlippageShare({
            makerShareBps: 0,
            takerShareBps: 0,
            protocolShareBps: 10000, // Default to 100% protocol capture natively
            totalBps: 10000 // 100% denominator
        });
    }

    /// @notice Set the only router contract that can settle routed legs
    function setTrustedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert InvalidAddress();
        trustedRouter = router;
        emit TrustedRouterSet(router);
    }

    // ============ Deposit Functions ============

    /// @notice Standard deposit (approve vault first, then deposit).
    /// @dev Frozen users cannot deposit, checked in vault.
    function depositFund(address _token, address _owner, uint256 _value) external whenNotPaused {
        if (msg.sender != _owner) revert UnauthorizedDepositCaller();
        if (!tokenConfigs[_token].isWhitelisted) revert TokenNotWhitelisted(_token);
        vault.deposit(_owner, _token, _value);
    }

    /// @notice Permit + Deposit: Allows using a larger permit amount but depositing a specific (smaller) amount
    /// @dev Useful for avoiding dust in Vault when swap amount is dynamic or less than allowance.
    ///      Supports both 65-byte standard (r, s, v) and 64-byte EIP-2098 compact (r, vs) signatures.
    /// @param _token Token to deposit
    /// @param _owner Owner of the tokens
    /// @param _permitAmount Amount signed in the permit (allowance)
    /// @param _depositAmount Amount to actually move to Vault (must be <= _permitAmount)
    /// @param _deadline Permit deadline
    /// @param _sig Permit signature (65 or 64 bytes)
    function depositFundWithPermit(
        address _token,
        address _owner,
        uint256 _permitAmount,
        uint256 _depositAmount,
        uint256 _deadline,
        bytes calldata _sig
    ) external whenNotPaused {
        if (!tokenConfigs[_token].isWhitelisted) revert TokenNotWhitelisted(_token);
        if (_depositAmount > _permitAmount) revert AmountMismatch();

        // Check if allowance is already sufficient (e.g., if front-run or previously permitted)
        if (IERC20(_token).allowance(_owner, address(vault)) < _depositAmount) {
            if (_sig.length != 65 && _sig.length != 64) revert InvalidSignatureLength();
            bytes32 r;
            bytes32 s;
            uint8 v;
            if (_sig.length == 65) {
                // Standard 65-byte signature: (r, s, v)
                assembly {
                    r := calldataload(_sig.offset)
                    s := calldataload(add(_sig.offset, 0x20))
                    v := byte(0, calldataload(add(_sig.offset, 0x40)))
                }
                if (v < 27) v += 27;
            } else {
                // EIP-2098 compact 64-byte signature: (r, vs)
                // vs = (v_parity << 255) | s
                bytes32 vs;
                assembly {
                    r := calldataload(_sig.offset)
                    vs := calldataload(add(_sig.offset, 0x20))
                }
                s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
                v = uint8((uint256(vs) >> 255)) + 27;
            }
            try IERC20Permit(_token).permit(_owner, address(vault), _permitAmount, _deadline, v, r, s) {} catch {}
        }
        vault.deposit(_owner, _token, _depositAmount);
    }

    // ============ Withdraw Functions ============

    /**
     * @notice Two-step delayed withdrawal: same function for request and execute
     * @dev First call: initiates request and starts delay timer.
     *      Second call: executes withdrawal after delay period.
     *      Frozen users can withdraw. Reverts if balance drops below requested amount.
     * @param token Token to withdraw
     * @param amount Amount to withdraw (must match request amount on execution)
     */
    function emergencyWithdraw(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidToken(token);
        if (amount == 0) revert InvalidAmount();

        WithdrawRequest storage request = withdrawRequests[msg.sender][token];

        // If no request exists OR the request has expired, treat it as a new request
        if (request.requestBlock == 0 || block.number > request.requestBlock + WITHDRAW_EXPIRATION_BLOCKS) {
            // Verify user has sufficient balance at request time to prevent cooldown bypass
            if (vault.balanceOf(token, msg.sender) < amount) revert WithdrawInsufficientBalance();
            request.requestBlock = block.number;
            request.amount = amount;
            emit WithdrawRequested(msg.sender, token, amount, block.number);
            return;
        }

        uint256 blocksPassed = block.number - request.requestBlock;
        if (blocksPassed < WITHDRAW_DELAY_BLOCKS) revert WithdrawNotReady();
        if (amount > request.amount) revert AmountMismatch();

        delete withdrawRequests[msg.sender][token];

        vault.withdraw(msg.sender, token, amount, msg.sender);
        emit Withdraw(token, msg.sender, amount);
    }

    /**
     * @notice Instant bulk withdrawal with dual authorization (user signature + executor signature)
     * @dev Allows frozen users to withdraw. Anybody can submit this transaction.
     *      Supports both EOA and ERC-1271 contract wallets for both user and executor signatures.
     * @param intent User's signed withdraw intent (supports multiple tokens up to 20)
     * @param userSignature User's EIP-712 signature
     * @param executor Address of the executor (must have EXECUTOR_ROLE)
     * @param executorSignature Executor's EIP-712 signature approving the exact same intent
     */
    function executeInstantWithdrawDualSig(
        WithdrawIntent calldata intent,
        bytes calldata userSignature,
        address executor,
        bytes calldata executorSignature
    ) external whenNotPaused nonReentrant {
        if (intent.deadline <= block.timestamp) revert IntentExpired();
        if (isUuidExecuted[intent.user][intent.uuid]) revert UuidAlreadyUsed();
        if (intent.tokens.length != intent.amounts.length) revert LengthMismatch();
        if (intent.tokens.length == 0 || intent.tokens.length > 20) revert InvalidTokenCount();
        if (!hasRole(EXECUTOR_ROLE, executor)) revert InvalidSignature();

        bytes32 sorHash = keccak256(
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                intent.user,
                SeraLib.hashAddressArray(intent.tokens),
                SeraLib.hashUint256Array(intent.amounts),
                intent.recipient,
                intent.deadline,
                intent.uuid
            )
        );

        _validateSignature(intent.user, sorHash, userSignature);
        _validateSignature(executor, sorHash, executorSignature);

        isUuidExecuted[intent.user][intent.uuid] = true;

        address recipient = intent.recipient == address(0) ? intent.user : intent.recipient;

        uint256 len = intent.tokens.length;
        for (uint256 i = 0; i < len;) {
            if (intent.amounts[i] == 0) revert InvalidAmount();
            if (intent.tokens[i] == address(0)) revert InvalidToken(intent.tokens[i]);
            vault.withdraw(intent.user, intent.tokens[i], intent.amounts[i], recipient);
            emit InstantWithdraw(intent.user, intent.uuid, intent.tokens[i], intent.amounts[i], recipient);
            unchecked {
                ++i;
            }
        }
    }

    // ============ Order Functions ============

    // ============ Matching Functions ============

    /**
     * @notice Match two complementary orders with token symmetry validation
     * @dev Validates signatures, availability, and executes match.
     *      Atomic primitive used by SeraBatcher.
     * @param _match Match data containing both orders and signatures
     */
    function matchOrders(MatchData calldata _match, uint256 deadline) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        if (block.timestamp > deadline) revert MatchExpired();
        // Token symmetry (checked first to save gas on revert)
        if (_match.order0.fromToken != _match.order1.toToken || _match.order1.fromToken != _match.order0.toToken) {
            revert TokenMismatch();
        }
        // Reject same-token pairs: prevents withdrawal-like settlement bypassing the 24h delay
        if (_match.order0.fromToken == _match.order0.toToken) revert SameTokenMatch();

        bytes32 orderHash0 = SeraLib.getOrderHashCalldata(_match.order0);
        bytes32 orderHash1 = SeraLib.getOrderHashCalldata(_match.order1);

        // Prevent matching an order against itself (double filledAmount increment)
        if (orderHash0 == orderHash1) revert SelfMatch();

        // Make sure the orders are valid, hash check is performed in this function
        // Note: Transaction is simulated off-chain, so revert gas is less critical, but strict ordering is good practice.
        _validateMakerOrder(_match.order0, orderHash0, _match.signature0, _match.matchAmount0);
        _validateMakerOrder(_match.order1, orderHash1, _match.signature1, _match.matchAmount1);

        _executeMatch(_match, orderHash0, orderHash1);
    }

    /**
     * @notice Core order matching execution with price validation, fee capture, and settlement.
     * @dev Inlined from former _collectAndDistribute to save one internal call frame (~200 gas).
     *
     *      Spread allocation note: when makerShareBps != takerShareBps, the surplus split depends
     *      on which order the executor places in the order0 (taker-share) vs order1 (maker-share) slot.
     *      Both users are guaranteed at least their signed limit price regardless of ordering.
     *      The spread above those limits is surplus, and its allocation is an EXECUTOR_ROLE operational
     *      decision — the same trusted role that selects which orders to match and at what amounts.
     *      For routed legs (settleRoutedLeg), the taker/maker distinction is structurally unambiguous.
     */
    function _executeMatch(MatchData calldata _match, bytes32 orderHash0, bytes32 orderHash1) internal {
        // Calculate the execution values for both orders
        (uint256 executionValue0, uint256 executionValue1) = SeraLib._executionValues(_match, _match.matchAmount0, _match.matchAmount1);

        SettlementCalc memory calc =
            _calculateSettlement(_match, executionValue0, executionValue1, _match.matchAmount0, _match.matchAmount1, orderHash0, orderHash1, true);

        _executeVaultSettlement(
            _match.order0.user,
            _match.order1.user,
            _match.order1.recipient,
            _match.order0.fromToken,
            calc.executionValue1 - calc.protocolFee0,
            calc.protocolTake0
        );

        _executeVaultSettlement(
            _match.order1.user,
            _match.order0.user,
            _match.order0.recipient,
            _match.order1.fromToken,
            calc.executionValue0 - calc.protocolFee1,
            calc.protocolTake1
        );

        emit OrderMatched(
            orderHash0,
            _match.order0.user,
            _match.order0.fromToken,
            _match.matchAmount0,
            calc.protocolTake0,
            orderHash1,
            _match.order1.user,
            _match.order1.fromToken,
            _match.matchAmount1,
            calc.protocolTake1
        );

        if (calc.order0FullyFilled) {
            emit OrderFullyFilled(orderHash0, _match.order0.user);
        }
        if (calc.order1FullyFilled) {
            emit OrderFullyFilled(orderHash1, _match.order1.user);
        }
    }

    /// @notice Computed fee/spread/fill results shared by standalone and routed settlement.
    struct SettlementCalc {
        uint256 protocolFee0;
        uint256 protocolFee1;
        uint256 protocolTake0;
        uint256 protocolTake1;
        uint256 executionValue0;
        uint256 executionValue1;
        bool order0FullyFilled;
        bool order1FullyFilled;
    }

    /// @notice Compute fees, spreads, update filled amounts, and return settlement results.
    /// @dev Spread is divided into protocol, maker (order1), and taker (order0) shares.
    ///      In matchOrders, both sides are limit orders with no intrinsic role — the executor's
    ///      input ordering determines who receives which share. This is by design: the executor
    ///      is a trusted role. In settleRoutedLeg, order0 is always the SOR taker.
    function _calculateSettlement(
        MatchData calldata _match,
        uint256 executionValue0,
        uint256 executionValue1,
        uint256 effectiveAmount0,
        uint256 effectiveAmount1,
        bytes32 orderHash0,
        bytes32 orderHash1,
        bool trackOrder0
    ) internal returns (SettlementCalc memory calc) {
        SlippageShare memory shares = slippageShares;

        // Protocol takes protocol fee AND its configured portion of the spread
        calc.protocolFee0 = Math.mulDiv(executionValue1, _match.order1.feeBps, BPS_DENOMINATOR);
        calc.protocolFee1 = Math.mulDiv(executionValue0, _match.order0.feeBps, BPS_DENOMINATOR);

        uint256 totalSpread0 = effectiveAmount0 - executionValue1;
        uint256 totalSpread1 = effectiveAmount1 - executionValue0;

        uint256 protocolSpread0 = Math.mulDiv(totalSpread0, shares.protocolShareBps, shares.totalBps);
        uint256 spreadToMaker0 = Math.mulDiv(totalSpread0, shares.makerShareBps, shares.totalBps);
        // spreadToTaker0 is the residual left in order0.user's deposit (implicit rebate).

        uint256 protocolSpread1 = Math.mulDiv(totalSpread1, shares.protocolShareBps, shares.totalBps);
        uint256 spreadToMaker1 = Math.mulDiv(totalSpread1, shares.makerShareBps, shares.totalBps);
        uint256 spreadToTaker1 = totalSpread1 - protocolSpread1 - spreadToMaker1;

        // Refund non-protocol spread to users by manipulating payouts.
        // Token 0 leg (executionValue1 is paid to order1.user = maker):
        // - Maker explicitly receives `spreadToMaker0` via executionValue1 payout increase.
        // - Taker implicitly retains `spreadToTaker0` (not pulled from their deposit).
        calc.executionValue1 = executionValue1 + spreadToMaker0;

        // Token 1 leg (executionValue0 is paid to order0.user = taker):
        // - Taker explicitly receives `spreadToTaker1` via executionValue0 payout increase.
        // - Maker implicitly retains `spreadToMaker1` (not pulled from their deposit).
        calc.executionValue0 = executionValue0 + spreadToTaker1;

        // Protocol take is the sum of protocol fee and spread
        calc.protocolTake0 = calc.protocolFee0 + protocolSpread0;
        calc.protocolTake1 = calc.protocolFee1 + protocolSpread1;

        // order0's fill is persisted ONLY on the signature-checked matchOrders path (trackOrder0=true).
        // On the signature-EXEMPT SOR taker path (trackOrder0=false) it is intentionally NOT written:
        // the taker is bounded by the SOR envelope (maxInput/minOutput) + consumeIntentUuid, and writing
        // the shared filledAmount for an unsigned taker leg is what let a taker-seeded hash disable the
        // maker signature check in matchOrders.
        if (trackOrder0) {
            filledAmount[orderHash0] += effectiveAmount0;
            calc.order0FullyFilled = (filledAmount[orderHash0] >= _match.order0.fromAmount);
        } else {
            calc.order0FullyFilled = (effectiveAmount0 >= _match.order0.fromAmount);
        }
        filledAmount[orderHash1] += effectiveAmount1;
        calc.order1FullyFilled = (filledAmount[orderHash1] >= _match.order1.fromAmount);
    }

    function _executeVaultSettlement(
        address fromUser,
        address toUser,
        address recipient,
        address token,
        uint256 payoutAmount,
        uint256 treasuryAmount
    ) internal {
        if (payoutAmount > 0) {
            if (recipient == address(0)) {
                // Internal ledger swap (no physical ERC20 transfer required)
                vault.transferLedger(fromUser, toUser, token, payoutAmount);
            } else {
                // Withdraw physical funds to the external wallet
                vault.withdraw(fromUser, token, payoutAmount, recipient);
            }
        }

        // Transfer protocol take to treasury in vault
        if (treasuryAmount > 0) {
            vault.transferLedger(fromUser, treasury, token, treasuryAmount);
        }
    }

    // ============ Internal Functions ============

    function _validateMakerOrder(Order calldata order, bytes32 orderHash, bytes calldata signature, uint256 matchAmount)
        internal
        view
    {
        uint256 filled = _validateOrderCommon(order, orderHash, matchAmount);

        // Validate signature using the already-computed orderHash only if it's the first time. Saves gas for partially filled, verified orders.
        if (filled == 0) {
            _validateSignature(order.user, orderHash, signature);
        }

        // Prevent ghost liquidity by checking actual vault balance
        if (vault.balanceOf(order.fromToken, order.user) < matchAmount) revert InsufficientVaultBalance();
    }

    /// @notice Common order validation checks shared between standalone and SOR paths
    function _validateOrderCommon(Order calldata order, bytes32 orderHash, uint256 matchAmount)
        internal
        view
        returns (uint256 filled)
    {
        if (matchAmount == 0) revert InvalidAmount();

        if (order.expiration <= block.timestamp) revert OrderExpired();
        if (vault.isBlacklisted(order.user)) revert IVault.BlacklistedUser(order.user);

        filled = filledAmount[orderHash];

        if (filled + matchAmount > order.fromAmount) revert OrderFilledAmountExceeded();

        // First time validations, skipped for subsequent fills to save gas
        if (filled == 0) {
            if (order.fromAmount == 0 || order.toAmount == 0) revert InvalidAmount();
            // Caps remaining lifetime at execution, not total lifetime since signing.
            // A signature with a distant expiration may initially fail this check but become
            // acceptable once block.timestamp advances close enough — this is by design.
            if (order.expiration > block.timestamp + MAX_EXPIRATION) revert OrderExpirationTooLong();
            if (order.feeBps > BPS_DENOMINATOR) revert InvalidFee(); // Not more than 100% fee

            TokenConfig memory config = tokenConfigs[order.fromToken];
            if (!config.isWhitelisted) revert TokenNotWhitelisted(order.fromToken);
            if (order.fromAmount < config.minAmount) revert AmountBelowMinimum(order.fromAmount, config.minAmount);
        }
    }

    /**
     * @notice Recover signer from EIP-712 digest and validate against expected user
     * @dev Supports both 64-byte (compact) and 65-byte (standard) signatures
     * @param _user Expected signer address
     * @param _structHash EIP-712 struct hash
     * @param _sig Signature bytes (64 or 65 bytes)
     */
    function _validateSignature(address _user, bytes32 _structHash, bytes calldata _sig) internal view {
        bytes32 digest = _hashTypedData(_structHash);
        if (!SignatureChecker.isValidSignatureNowCalldata(_user, digest, _sig)) revert InvalidSignature();
    }

    /// @notice Build EIP-712 digest for an SOR payload under Sera domain
    /// @dev Used by SeraSOR for SOR flexible routing. Named 'getIntentDigest' for legacy reasons.
    function getIntentDigest(
        address taker,
        address inputToken, address outputToken,
        uint256 maxInputAmount, uint256 minOutputAmount,
        address recipient, uint256 initialDepositAmount,
        uint256 uuid, uint48 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            INTENT_TYPEHASH, taker, inputToken, outputToken,
            maxInputAmount, minOutputAmount, recipient, initialDepositAmount, uuid, deadline
        ));
        return _hashTypedData(structHash);
    }

    /// @dev Required implementation for solady EIP712
    /// @dev ChainID etc not needed for solday EIP712
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Sera";
        version = "1";
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparator();
    }

    // ============ SOR Intent Replay Protection (called by SeraSOR) ============

    /// @notice Mark an intent UUID as consumed. Only callable by the trusted router.
    /// @dev Centralizes replay protection in Sera so multiple router deployments cannot replay the same intent (SFO-17).
    function consumeIntentUuid(address user, uint256 uuid) external {
        if (msg.sender != trustedRouter) revert RouterNotTrusted();
        if (isIntentUuidUsed[user][uuid]) revert UuidAlreadyUsed();
        isIntentUuidUsed[user][uuid] = true;
    }

    // ============ Routed Settlement (called by SeraSOR) ============

    /**
     * @notice Settle a single leg of a routed match (called by SeraSOR).
     * @dev Skips taker signature (handled by SOR), supports transient balances.
     * @param _match The match data for this leg
     * @param takerVaultPull Amount to pull from vault for taker (0 if fully from transient held in Sera)
     * @param holdTakerOutput If true, hold taker's output tokens in Sera for next leg
     * @return takerReceives Amount of output tokens the taker receives (after fees)
     */
    function settleRoutedLeg(MatchData calldata _match, uint256 takerVaultPull, bool holdTakerOutput, uint256 effectiveMatchAmount0)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 takerReceives, bytes32 takerHash, bytes32 makerHash)
    {
        if (msg.sender != trustedRouter) revert RouterNotTrusted();

        takerHash = SeraLib.getOrderHashCalldata(_match.order0);
        makerHash = SeraLib.getOrderHashCalldata(_match.order1);

        // Taker: common checks only (no sig — SeraSOR authorized)
        _validateOrderCommon(_match.order0, takerHash, effectiveMatchAmount0);

        // Not applicable assuming SeraSOR.sol (trustedRouter) is flawless, but retained to maintain defensive coding
        if (takerVaultPull > effectiveMatchAmount0) revert InvalidAmount();

        // Vault balance check only for amount actually pulled
        // Since we now optimize vault pulls inside _settleRoutedLegInternal, the full pull might not happen.
        // However, we still check against the max possible pull here for early revert/security.
        if (takerVaultPull > 0) {
            if (vault.balanceOf(_match.order0.fromToken, _match.order0.user) < takerVaultPull) {
                revert InsufficientVaultBalance();
            }
        }

        // Token symmetry (checked before expensive signature validation)
        if (_match.order0.fromToken != _match.order1.toToken || _match.order1.fromToken != _match.order0.toToken) {
            revert TokenMismatch();
        }

        // SFO-05: Same guards as matchOrders — reject same-token legs and self-matches
        if (_match.order0.fromToken == _match.order0.toToken) revert SameTokenMatch();
        if (takerHash == makerHash) revert SelfMatch();

        // Maker: full validation (sig + routeHash must be 0)
        _validateMakerOrder(_match.order1, makerHash, _match.signature1, _match.matchAmount1);

        takerReceives = _settleRoutedLegInternal(_match, takerHash, makerHash, takerVaultPull, holdTakerOutput, effectiveMatchAmount0);
    }

    /**
     * @notice Internal settlement for a routed leg with transient balance support.
     * @dev Handles fee/spread calc, filled amounts, vault pulls, distribution, and events.
     */
    function _settleRoutedLegInternal(
        MatchData calldata _match,
        bytes32 takerHash,
        bytes32 makerHash,
        uint256 takerVaultPull,
        bool holdTakerOutput,
        uint256 effectiveMatchAmount0
    ) internal returns (uint256 takerReceives) {
        (uint256 executionValue0, uint256 executionValue1) = SeraLib._executionValues(_match, effectiveMatchAmount0, _match.matchAmount1);
        SettlementCalc memory calc =
            _calculateSettlement(_match, executionValue0, executionValue1, effectiveMatchAmount0, _match.matchAmount1, takerHash, makerHash, false);

        // Cache hot storage/calldata fields to avoid redundant reads
        address takerFromToken = _match.order0.fromToken;
        address makerFromToken = _match.order1.fromToken;
        address _treasury = treasury;

        uint256 makerReceives = calc.executionValue1 - calc.protocolFee0;
        uint256 neededFromTaker = makerReceives + calc.protocolTake0;
        
        // Calculate the amount of transient physical tokens already resting inside Sera.sol from previous legs or wallet deposits
        uint256 transientPhysical = effectiveMatchAmount0 - takerVaultPull;

        if (neededFromTaker > transientPhysical) {
            // Deficit: We must pull the remaining difference from the user's vault
            uint256 actualPull = neededFromTaker - transientPhysical;
            
            // Defensive check: This should be mathematically impossible since neededFromTaker <= effectiveMatchAmount0
            // but we bound the pull strictly against takerVaultPull to guarantee no unexpected behavior
            if (actualPull > takerVaultPull) {
                actualPull = takerVaultPull;
            }
            
            if (actualPull > 0) {
                vault.withdraw(_match.order0.user, takerFromToken, actualPull, address(this));
            }
        } else if (transientPhysical > neededFromTaker) {
            // Surplus: The transient tokens alone exceed the cost. 
            // No vault pull is needed, and we return the surplus transient physical tokens securely to their vault ledger
            uint256 physicalSurplus = transientPhysical - neededFromTaker;
            IERC20(takerFromToken).safeTransfer(address(vault), physicalSurplus);
            vault.creditLedger(_match.order0.user, takerFromToken, physicalSurplus);
        }

        // Process maker side (Token 1) via Vault internal transfers
        takerReceives = calc.executionValue0 - calc.protocolFee1;

        // If holding output, recipient is Sera (address(this)). Otherwise, it's the taker's requested recipient.
        address takerRecipient = holdTakerOutput ? address(this) : _match.order0.recipient;

        _executeVaultSettlement(
            _match.order1.user, // fromUser (Maker)
            _match.order0.user, // toUser (Taker)
            takerRecipient, // recipient
            makerFromToken, // token
            takerReceives, // payoutAmount
            calc.protocolTake1 // treasuryAmount
        );

        // Process taker side (Token 0) physically (tokens are in Sera.sol)
        if (makerReceives > 0) {
            address makerRecipient = _match.order1.recipient;
            if (makerRecipient == address(0)) {
                // No external recipient: credit maker's vault ledger
                IERC20(takerFromToken).safeTransfer(address(vault), makerReceives);
                vault.creditLedger(_match.order1.user, takerFromToken, makerReceives);
            } else {
                IERC20(takerFromToken).safeTransfer(makerRecipient, makerReceives);
            }
        }

        if (calc.protocolTake0 > 0) {
            // Physical tokens are currently in Sera. Send them to Vault and credit treasury ledger.
            IERC20(takerFromToken).safeTransfer(address(vault), calc.protocolTake0);
            vault.creditLedger(_treasury, takerFromToken, calc.protocolTake0);
        }

        // Emit standard events
        emit OrderMatched(
            takerHash,
            _match.order0.user,
            takerFromToken,
            effectiveMatchAmount0,
            calc.protocolTake0,
            makerHash,
            _match.order1.user,
            makerFromToken,
            _match.matchAmount1,
            calc.protocolTake1
        );
        if (calc.order0FullyFilled) emit OrderFullyFilled(takerHash, _match.order0.user);
        if (calc.order1FullyFilled) emit OrderFullyFilled(makerHash, _match.order1.user);
    }
}
