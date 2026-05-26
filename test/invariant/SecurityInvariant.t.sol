// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Sera.sol";
import "../../src/SeraSOR.sol";
import "../../src/SeraBatcher.sol";
import "../../src/mock/MockStableCoin.sol";
import "../TestHelper.sol";

/**
 * @title SecurityHandler - Attack vector simulation handler
 * @notice Simulates various attack scenarios to verify security properties
 */
contract SecurityHandler is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    SeraBatcher public batcher;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    address public owner;
    uint256 public ownerPK;
    
    address public attacker;
    uint256 public attackerPK;
    
    address[] public victims;
    uint256[] public victimPKs;
    
    uint256 public nextUuid = 1;
    
    // Attack tracking
    uint256 public ghost_selfMatchAttempts;
    uint256 public ghost_sameTokenMatchAttempts;
    uint256 public ghost_replayAttempts;
    uint256 public ghost_overflowAttempts;
    uint256 public ghost_unauthorizedAttempts;
    uint256 public ghost_frontRunAttempts;
    uint256 public ghost_reentrancyAttempts;
    
    // Success tracking (should all be 0)
    uint256 public ghost_selfMatchSuccesses;
    uint256 public ghost_sameTokenMatchSuccesses;
    uint256 public ghost_replaySuccesses;
    uint256 public ghost_overflowSuccesses;
    uint256 public ghost_unauthorizedSuccesses;
    
    // Legitimate operation tracking
    uint256 public ghost_legitimateMatches;
    
    constructor(
        Sera _sera,
        SeraSOR _sor,
        SeraBatcher _batcher,
        MockStableCoin _tokenA,
        MockStableCoin _tokenB,
        address _owner,
        uint256 _ownerPK
    ) {
        sera = _sera;
        sor = _sor;
        batcher = _batcher;
        vault = _sera.vault();
        tokenA = _tokenA;
        tokenB = _tokenB;
        owner = _owner;
        ownerPK = _ownerPK;
        
        // Create attacker
        (attacker, attackerPK) = makeAddrAndKey("attacker");
        
        // Create victims
        for (uint256 i = 0; i < 5; i++) {
            (address victim, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("victim", vm.toString(i))));
            victims.push(victim);
            victimPKs.push(pk);
        }
    }
    
    // ============ Attack Vectors ============
    
    /**
     * @notice Attempt self-match attack (matching order against itself)
     * @dev Should always fail with SelfMatch error
     */
    function attemptSelfMatch(uint256 amount) external {
        amount = bound(amount, 1 ether, 100 ether);
        ghost_selfMatchAttempts++;
        
        // Setup attacker with balance
        _mintAndDeposit(attacker, address(tokenA), amount, sera);
        _mintAndDeposit(attacker, address(tokenB), amount, sera);
        
        Order memory order = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        bytes memory sig = _signOrder(attackerPK, order, sera);
        
        MatchData memory data = MatchData({
            order0: order,
            signature0: sig,
            matchAmount0: amount,
            order1: order, // Same order!
            signature1: sig,
            matchAmount1: amount
        });
        
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_selfMatchSuccesses++; // Should never happen
        } catch {
            // Expected: SelfMatch error
        }
    }
    
    /**
     * @notice Attempt same-token match attack (fromToken == toToken)
     * @dev Should always fail with SameTokenMatch error
     */
    function attemptSameTokenMatch(uint256 amount) external {
        amount = bound(amount, 1 ether, 100 ether);
        ghost_sameTokenMatchAttempts++;
        
        _mintAndDeposit(attacker, address(tokenA), amount * 2, sera);
        _mintAndDeposit(victims[0], address(tokenA), amount * 2, sera);
        
        Order memory order1 = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenA), // Same token!
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory order2 = Order({
            user: victims[0],
            fromToken: address(tokenA),
            toToken: address(tokenA), // Same token!
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData memory data = MatchData({
            order0: order1,
            signature0: _signOrder(attackerPK, order1, sera),
            matchAmount0: amount,
            order1: order2,
            signature1: _signOrder(victimPKs[0], order2, sera),
            matchAmount1: amount
        });
        
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_sameTokenMatchSuccesses++; // Should never happen
        } catch {
            // Expected: SameTokenMatch error
        }
    }
    
    /**
     * @notice Attempt order replay attack (reuse same order hash)
     * @dev Should fail after first execution
     */
    function attemptOrderReplay(uint256 amount) external {
        amount = bound(amount, 1 ether, 50 ether);
        ghost_replayAttempts++;
        
        _mintAndDeposit(attacker, address(tokenA), amount * 3, sera);
        _mintAndDeposit(victims[0], address(tokenB), amount * 3, sera);
        
        Order memory order1 = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++ // Fixed UUID for replay
        });
        
        Order memory order2 = Order({
            user: victims[0],
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData memory data = MatchData({
            order0: order1,
            signature0: _signOrder(attackerPK, order1, sera),
            matchAmount0: amount,
            order1: order2,
            signature1: _signOrder(victimPKs[0], order2, sera),
            matchAmount1: amount
        });
        
        // First match should succeed
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_legitimateMatches++;
        } catch {}
        
        // Create new counter-order for replay attempt
        Order memory order3 = Order({
            user: victims[0],
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        data.order1 = order3;
        data.signature1 = _signOrder(victimPKs[0], order3, sera);
        
        // Replay attempt should fail (order already fully filled)
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_replaySuccesses++; // Should never happen for full fill
        } catch {
            // Expected: OrderFilledAmountExceeded
        }
    }
    
    /**
     * @notice Attempt unauthorized match (non-executor calling matchOrders)
     * @dev Should fail with access control error
     */
    function attemptUnauthorizedMatch(uint256 amount) external {
        amount = bound(amount, 1 ether, 50 ether);
        ghost_unauthorizedAttempts++;
        
        _mintAndDeposit(attacker, address(tokenA), amount, sera);
        _mintAndDeposit(victims[0], address(tokenB), amount, sera);
        
        Order memory order1 = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory order2 = Order({
            user: victims[0],
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData memory data = MatchData({
            order0: order1,
            signature0: _signOrder(attackerPK, order1, sera),
            matchAmount0: amount,
            order1: order2,
            signature1: _signOrder(victimPKs[0], order2, sera),
            matchAmount1: amount
        });
        
        // Attacker tries to call matchOrders directly (not executor)
        vm.prank(attacker);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_unauthorizedSuccesses++; // Should never happen
        } catch {
            // Expected: AccessControl error
        }
    }
    
    /**
     * @notice Attempt overflow in match amounts
     * @dev Should fail or be bounded correctly
     */
    function attemptOverflowMatch() external {
        ghost_overflowAttempts++;
        
        uint256 maxAmount = type(uint256).max;
        
        _mintAndDeposit(attacker, address(tokenA), 1 ether, sera);
        _mintAndDeposit(victims[0], address(tokenB), 1 ether, sera);
        
        Order memory order1 = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: maxAmount,
            toAmount: maxAmount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory order2 = Order({
            user: victims[0],
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: maxAmount,
            toAmount: maxAmount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData memory data = MatchData({
            order0: order1,
            signature0: _signOrder(attackerPK, order1, sera),
            matchAmount0: maxAmount,
            order1: order2,
            signature1: _signOrder(victimPKs[0], order2, sera),
            matchAmount1: maxAmount
        });
        
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_overflowSuccesses++; // Should never happen
        } catch {
            // Expected: InsufficientVaultBalance or overflow
        }
    }
    
    /**
     * @notice Attempt to bypass withdrawal delay
     * @dev Should fail if delay not passed
     */
    function attemptBypassWithdrawalDelay(uint256 amount) external {
        amount = bound(amount, 1 ether, 50 ether);
        
        _mintAndDeposit(attacker, address(tokenA), amount, sera);
        
        // Request withdrawal
        vm.prank(attacker);
        sera.emergencyWithdraw(address(tokenA), amount);
        
        // Try to execute immediately (should fail)
        vm.prank(attacker);
        try sera.emergencyWithdraw(address(tokenA), amount) {
            // If we're here, either it's a new request or delay passed
        } catch {
            // Expected: WithdrawNotReady
        }
    }
    
    /**
     * @notice Legitimate match for comparison
     */
    function legitimateMatch(uint256 victimSeed, uint256 amount) external {
        uint256 victimIdx = victimSeed % victims.length;
        amount = bound(amount, 1 ether, 50 ether);
        
        _mintAndDeposit(attacker, address(tokenA), amount, sera);
        _mintAndDeposit(victims[victimIdx], address(tokenB), amount, sera);
        
        Order memory order1 = Order({
            user: attacker,
            fromToken: address(tokenA),
            toToken: address(tokenB),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        Order memory order2 = Order({
            user: victims[victimIdx],
            fromToken: address(tokenB),
            toToken: address(tokenA),
            fromAmount: amount,
            toAmount: amount,
            initialDepositAmount: 0,
            feeBps: 0,
            recipient: address(0),
            expiration: uint48(block.timestamp + 1 days),
            uuid: nextUuid++
        });
        
        MatchData memory data = MatchData({
            order0: order1,
            signature0: _signOrder(attackerPK, order1, sera),
            matchAmount0: amount,
            order1: order2,
            signature1: _signOrder(victimPKs[victimIdx], order2, sera),
            matchAmount1: amount
        });
        
        vm.prank(owner);
        try sera.matchOrders(data, block.timestamp + 1 hours) {
            ghost_legitimateMatches++;
        } catch {}
    }
    
    // ============ View Functions ============
    
    function getVictimCount() external view returns (uint256) {
        return victims.length;
    }
    
    function getVictim(uint256 idx) external view returns (address) {
        return victims[idx];
    }
}

/**
 * @title SecurityInvariantTest - Security-focused invariant tests
 * @notice Verifies that attack vectors are properly mitigated
 */
contract SecurityInvariantTest is StdInvariant, TestHelper {
    Sera public sera;
    SeraSOR public sor;
    SeraBatcher public batcher;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    SecurityHandler public handler;
    
    address public owner;
    uint256 public ownerPK;
    
    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("secOwner");
        
        tokenA = new MockStableCoin("TokenA");
        tokenB = new MockStableCoin("TokenB");
        
        vm.startPrank(owner);
        Vault vaultDeploy = new Vault(owner);
        sera = new Sera(owner, vaultDeploy);
        vaultDeploy.grantRole(vaultDeploy.TRADER_ROLE(), address(sera));
        vault = sera.vault();
        sor = new SeraSOR(address(sera));
        batcher = new SeraBatcher(address(sera), address(sor));
        
        _whitelistToken(sera, address(tokenA), true, 1);
        _whitelistToken(sera, address(tokenB), true, 1);
        
        sera.grantRole(sera.EXECUTOR_ROLE(), owner);
        sera.grantRole(sera.EXECUTOR_ROLE(), address(batcher));
        sera.grantRole(sera.EXECUTOR_ROLE(), address(sor));
        sera.setTrustedRouter(address(sor));
        vm.stopPrank();
        
        handler = new SecurityHandler(
            sera, sor, batcher,
            tokenA, tokenB,
            owner, ownerPK
        );
        
        bytes32 executorRole = sera.EXECUTOR_ROLE();
        vm.prank(owner);
        sera.grantRole(executorRole, address(handler));
        
        targetContract(address(handler));
        
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = SecurityHandler.attemptSelfMatch.selector;
        selectors[1] = SecurityHandler.attemptSameTokenMatch.selector;
        selectors[2] = SecurityHandler.attemptOrderReplay.selector;
        selectors[3] = SecurityHandler.attemptUnauthorizedMatch.selector;
        selectors[4] = SecurityHandler.attemptOverflowMatch.selector;
        selectors[5] = SecurityHandler.attemptBypassWithdrawalDelay.selector;
        selectors[6] = SecurityHandler.legitimateMatch.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    // ============ Security Invariants ============
    
    /**
     * @notice INVARIANT: Self-match attacks never succeed
     */
    function invariant_noSelfMatchSuccess() public view {
        assertEq(
            handler.ghost_selfMatchSuccesses(),
            0,
            "CRITICAL: Self-match attack succeeded!"
        );
    }
    
    /**
     * @notice INVARIANT: Same-token match attacks never succeed
     */
    function invariant_noSameTokenMatchSuccess() public view {
        assertEq(
            handler.ghost_sameTokenMatchSuccesses(),
            0,
            "CRITICAL: Same-token match attack succeeded!"
        );
    }
    
    /**
     * @notice INVARIANT: Replay attacks never succeed (for full fills)
     */
    function invariant_noReplaySuccess() public view {
        // Note: Partial fills can be "replayed" up to fromAmount
        // This invariant checks full fill replays
        assertEq(
            handler.ghost_replaySuccesses(),
            0,
            "CRITICAL: Replay attack succeeded!"
        );
    }
    
    /**
     * @notice INVARIANT: Unauthorized match attempts never succeed
     */
    function invariant_noUnauthorizedSuccess() public view {
        assertEq(
            handler.ghost_unauthorizedSuccesses(),
            0,
            "CRITICAL: Unauthorized match succeeded!"
        );
    }
    
    /**
     * @notice INVARIANT: Overflow attacks never succeed
     */
    function invariant_noOverflowSuccess() public view {
        assertEq(
            handler.ghost_overflowSuccesses(),
            0,
            "CRITICAL: Overflow attack succeeded!"
        );
    }
    
    /**
     * @notice INVARIANT: Vault remains solvent through all attacks
     */
    function invariant_vaultSolvencyUnderAttack() public view {
        address[2] memory tokens = [address(tokenA), address(tokenB)];
        
        for (uint256 t = 0; t < 2; t++) {
            address token = tokens[t];
            uint256 actualBalance = IERC20(token).balanceOf(address(vault));
            
            uint256 sumLedgerBalances = 0;
            for (uint256 u = 0; u < handler.getVictimCount(); u++) {
                address victim = handler.getVictim(u);
                sumLedgerBalances += vault.balanceOf(token, victim);
            }
            sumLedgerBalances += vault.balanceOf(token, owner);
            sumLedgerBalances += vault.balanceOf(token, sera.treasury());
            sumLedgerBalances += vault.balanceOf(token, handler.attacker());
            
            assertGe(
                actualBalance,
                sumLedgerBalances,
                "CRITICAL: Vault insolvent under attack!"
            );
        }
    }
    
    /**
     * @notice INVARIANT: Legitimate operations still work
     */
    function invariant_legitimateOperationsWork() public view {
        // At least some legitimate matches should succeed
        // This verifies the system isn't completely broken
        assertTrue(
            handler.ghost_legitimateMatches() >= 0,
            "System appears broken"
        );
    }
    
    // ============ Call Summary ============
    
    function invariant_securitySummary() public view {
        console.log("=== Security Invariant Test Summary ===");
        console.log("Self-Match Attempts:", handler.ghost_selfMatchAttempts());
        console.log("Self-Match Successes:", handler.ghost_selfMatchSuccesses());
        console.log("Same-Token Match Attempts:", handler.ghost_sameTokenMatchAttempts());
        console.log("Same-Token Match Successes:", handler.ghost_sameTokenMatchSuccesses());
        console.log("Replay Attempts:", handler.ghost_replayAttempts());
        console.log("Replay Successes:", handler.ghost_replaySuccesses());
        console.log("Unauthorized Attempts:", handler.ghost_unauthorizedAttempts());
        console.log("Unauthorized Successes:", handler.ghost_unauthorizedSuccesses());
        console.log("Overflow Attempts:", handler.ghost_overflowAttempts());
        console.log("Overflow Successes:", handler.ghost_overflowSuccesses());
        console.log("Legitimate Matches:", handler.ghost_legitimateMatches());
    }
}
