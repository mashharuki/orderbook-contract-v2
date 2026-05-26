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
 * @title SeraBatcherHandler - Fuzzing handler for SeraBatcher invariant testing
 * @notice Simulates batch operations, atomic batches, and mixed mode executions
 */
contract SeraBatcherHandler is TestHelper {
    Sera public sera;
    SeraSOR public sor;
    SeraBatcher public batcher;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    address public owner;
    uint256 public ownerPK;
    
    address[] public users;
    uint256[] public userPKs;
    
    uint256 public nextUuid = 1;
    
    // Ghost variables
    uint256 public ghost_batchMatchCalls;
    uint256 public ghost_atomicBatchCalls;
    uint256 public ghost_mixedBatchCalls;
    uint256 public ghost_successfulMatches;
    uint256 public ghost_failedMatches;
    
    // Track batch sizes
    uint256 public ghost_maxBatchSizeUsed;
    uint256 public ghost_maxAtomicBatchSizeUsed;
    
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
        
        // Create test users
        for (uint256 i = 0; i < 10; i++) {
            (address user, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("batchUser", vm.toString(i))));
            users.push(user);
            userPKs.push(pk);
        }
    }
    
    // ============ Setup Helpers ============
    
    function _setupUserWithBalance(uint256 userIdx, address token, uint256 amount) internal {
        address user = users[userIdx];
        MockStableCoin(token).mint(user, amount);
        vm.startPrank(user);
        IERC20(token).approve(address(vault), amount);
        sera.depositFund(token, user, amount);
        vm.stopPrank();
    }
    
    function _createMatchData(
        uint256 user1Idx,
        uint256 user2Idx,
        uint256 amount
    ) internal returns (MatchData memory) {
        address user1 = users[user1Idx];
        address user2 = users[user2Idx];
        uint256 pk1 = userPKs[user1Idx];
        uint256 pk2 = userPKs[user2Idx];
        
        Order memory order1 = Order({
            user: user1,
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
            user: user2,
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
        
        return MatchData({
            order0: order1,
            signature0: _signOrder(pk1, order1, sera),
            matchAmount0: amount,
            order1: order2,
            signature1: _signOrder(pk2, order2, sera),
            matchAmount1: amount
        });
    }
    
    // ============ Batch Match Operations ============
    
    function batchMatchOrders(uint256 batchSize, uint256 amount) external {
        batchSize = bound(batchSize, 1, 5); // Keep small for gas
        amount = bound(amount, 1 ether, 10 ether);
        
        // Setup users with balances
        for (uint256 i = 0; i < batchSize * 2; i++) {
            uint256 userIdx = i % users.length;
            address token = (i % 2 == 0) ? address(tokenA) : address(tokenB);
            _setupUserWithBalance(userIdx, token, amount);
        }
        
        MatchData[] memory matches = new MatchData[](batchSize);
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 user1Idx = (i * 2) % users.length;
            uint256 user2Idx = (i * 2 + 1) % users.length;
            if (user1Idx == user2Idx) user2Idx = (user2Idx + 1) % users.length;
            
            matches[i] = _createMatchData(user1Idx, user2Idx, amount);
        }
        
        if (batchSize > ghost_maxBatchSizeUsed) {
            ghost_maxBatchSizeUsed = batchSize;
        }
        
        vm.prank(owner);
        try batcher.batchMatchOrders(matches, block.timestamp + 1 hours) returns (uint256 failedMask) {
            ghost_batchMatchCalls++;
            
            // Count successes and failures
            for (uint256 i = 0; i < batchSize; i++) {
                if ((failedMask & (1 << i)) == 0) {
                    ghost_successfulMatches++;
                } else {
                    ghost_failedMatches++;
                }
            }
        } catch {
            ghost_failedMatches += batchSize;
        }
    }
    
    function batchMatchOrdersAtomic(uint256 batchSize, uint256 amount) external {
        batchSize = bound(batchSize, 1, 3); // Keep very small for atomic
        amount = bound(amount, 1 ether, 10 ether);
        
        // Setup users with balances
        for (uint256 i = 0; i < batchSize * 2; i++) {
            uint256 userIdx = i % users.length;
            address token = (i % 2 == 0) ? address(tokenA) : address(tokenB);
            _setupUserWithBalance(userIdx, token, amount);
        }
        
        MatchData[] memory matches = new MatchData[](batchSize);
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 user1Idx = (i * 2) % users.length;
            uint256 user2Idx = (i * 2 + 1) % users.length;
            if (user1Idx == user2Idx) user2Idx = (user2Idx + 1) % users.length;
            
            matches[i] = _createMatchData(user1Idx, user2Idx, amount);
        }
        
        if (batchSize > ghost_maxAtomicBatchSizeUsed) {
            ghost_maxAtomicBatchSizeUsed = batchSize;
        }
        
        vm.prank(owner);
        try batcher.batchMatchOrdersAtomic(matches, block.timestamp + 1 hours) {
            ghost_atomicBatchCalls++;
            ghost_successfulMatches += batchSize;
        } catch {
            ghost_failedMatches += batchSize;
        }
    }
    
    function batchMatchMixed(
        uint256 atomicBatchCount,
        uint256 singleMatchCount,
        uint256 amount
    ) external {
        atomicBatchCount = bound(atomicBatchCount, 0, 2);
        singleMatchCount = bound(singleMatchCount, 0, 3);
        amount = bound(amount, 1 ether, 10 ether);
        
        if (atomicBatchCount == 0 && singleMatchCount == 0) return;
        
        // Setup users
        uint256 totalUsers = (atomicBatchCount * 2 + singleMatchCount * 2);
        for (uint256 i = 0; i < totalUsers && i < users.length; i++) {
            address token = (i % 2 == 0) ? address(tokenA) : address(tokenB);
            _setupUserWithBalance(i, token, amount);
        }
        
        // Create atomic batches
        SeraBatcher.AtomicBatch[] memory atomicBatches = new SeraBatcher.AtomicBatch[](atomicBatchCount);
        for (uint256 i = 0; i < atomicBatchCount; i++) {
            MatchData[] memory batchMatches = new MatchData[](1);
            uint256 user1Idx = (i * 2) % users.length;
            uint256 user2Idx = (i * 2 + 1) % users.length;
            if (user1Idx == user2Idx) user2Idx = (user2Idx + 1) % users.length;
            
            batchMatches[0] = _createMatchData(user1Idx, user2Idx, amount);
            atomicBatches[i] = SeraBatcher.AtomicBatch({matches: batchMatches});
        }
        
        // Create single matches
        MatchData[] memory singleMatches = new MatchData[](singleMatchCount);
        for (uint256 i = 0; i < singleMatchCount; i++) {
            uint256 offset = atomicBatchCount * 2;
            uint256 user1Idx = (offset + i * 2) % users.length;
            uint256 user2Idx = (offset + i * 2 + 1) % users.length;
            if (user1Idx == user2Idx) user2Idx = (user2Idx + 1) % users.length;
            
            singleMatches[i] = _createMatchData(user1Idx, user2Idx, amount);
        }
        
        // Empty intents array
        SeraBatcher.IntentExecution[] memory intents = new SeraBatcher.IntentExecution[](0);
        
        vm.prank(owner);
        try batcher.batchMatchMixed(atomicBatches, singleMatches, intents, block.timestamp + 1 hours) returns (uint256 failedMask) {
            ghost_mixedBatchCalls++;
            
            // Count results
            uint256 totalOps = atomicBatchCount + singleMatchCount;
            for (uint256 i = 0; i < totalOps; i++) {
                if ((failedMask & (1 << i)) == 0) {
                    ghost_successfulMatches++;
                } else {
                    ghost_failedMatches++;
                }
            }
        } catch {
            ghost_failedMatches += atomicBatchCount + singleMatchCount;
        }
    }
    
    // ============ Edge Cases ============
    
    function attemptOversizedBatch(uint256 size) external {
        size = bound(size, 21, 25); // Exceed MAX_BATCH_SIZE
        
        // This should always fail
        MatchData[] memory matches = new MatchData[](size);
        
        vm.prank(owner);
        try batcher.batchMatchOrders(matches, block.timestamp + 1 hours) {
            revert("Should have reverted for oversized batch");
        } catch {
            // Expected
        }
    }
    
    function attemptExpiredDeadline(uint256 amount) external {
        amount = bound(amount, 1 ether, 10 ether);
        
        _setupUserWithBalance(0, address(tokenA), amount);
        _setupUserWithBalance(1, address(tokenB), amount);
        
        MatchData[] memory matches = new MatchData[](1);
        matches[0] = _createMatchData(0, 1, amount);
        
        // Use expired deadline
        vm.prank(owner);
        try batcher.batchMatchOrders(matches, block.timestamp - 1) {
            revert("Should have reverted for expired deadline");
        } catch {
            // Expected
        }
    }
    
    // ============ View Functions ============
    
    function getUserCount() external view returns (uint256) {
        return users.length;
    }
    
    function getUser(uint256 idx) external view returns (address) {
        return users[idx];
    }
}

/**
 * @title SeraBatcherInvariantTest - Invariant tests for SeraBatcher
 * @notice Tests batch size limits, atomic execution, and mixed mode operations
 */
contract SeraBatcherInvariantTest is StdInvariant, TestHelper {
    Sera public sera;
    SeraSOR public sor;
    SeraBatcher public batcher;
    Vault public vault;
    
    MockStableCoin public tokenA;
    MockStableCoin public tokenB;
    
    SeraBatcherHandler public handler;
    
    address public owner;
    uint256 public ownerPK;
    
    function setUp() public {
        (owner, ownerPK) = makeAddrAndKey("batcherOwner");
        
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
        
        handler = new SeraBatcherHandler(
            sera, sor, batcher,
            tokenA, tokenB,
            owner, ownerPK
        );
        
        bytes32 executorRole = sera.EXECUTOR_ROLE();
        vm.prank(owner);
        sera.grantRole(executorRole, address(handler));
        
        targetContract(address(handler));
        
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SeraBatcherHandler.batchMatchOrders.selector;
        selectors[1] = SeraBatcherHandler.batchMatchOrdersAtomic.selector;
        selectors[2] = SeraBatcherHandler.batchMatchMixed.selector;
        selectors[3] = SeraBatcherHandler.attemptOversizedBatch.selector;
        selectors[4] = SeraBatcherHandler.attemptExpiredDeadline.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    // ============ Core Invariants ============
    
    /**
     * @notice INVARIANT: MAX_BATCH_SIZE constant is 20
     */
    function invariant_maxBatchSizeConstant() public view {
        assertEq(batcher.MAX_BATCH_SIZE(), 20);
    }
    
    /**
     * @notice INVARIANT: MAX_INTENT_SIZE constant is 10
     */
    function invariant_maxIntentSizeConstant() public view {
        assertEq(batcher.MAX_INTENT_SIZE(), 10);
    }
    
    /**
     * @notice INVARIANT: SOR reference is immutable and non-zero
     */
    function invariant_sorReferenceImmutable() public view {
        assertEq(address(batcher.sor()), address(sor));
        assertTrue(address(batcher.sor()) != address(0));
    }
    
    /**
     * @notice INVARIANT: Sera reference is immutable and non-zero
     */
    function invariant_seraReferenceImmutable() public view {
        assertEq(address(batcher.sera()), address(sera));
        assertTrue(address(batcher.sera()) != address(0));
    }
    
    /**
     * @notice INVARIANT: Vault solvency maintained through batch operations
     */
    function invariant_vaultSolvencyAfterBatch() public view {
        address[2] memory tokens = [address(tokenA), address(tokenB)];
        
        for (uint256 t = 0; t < 2; t++) {
            address token = tokens[t];
            uint256 actualBalance = IERC20(token).balanceOf(address(vault));
            
            uint256 sumLedgerBalances = 0;
            for (uint256 u = 0; u < handler.getUserCount(); u++) {
                address user = handler.getUser(u);
                sumLedgerBalances += vault.balanceOf(token, user);
            }
            sumLedgerBalances += vault.balanceOf(token, owner);
            sumLedgerBalances += vault.balanceOf(token, sera.treasury());
            
            assertGe(actualBalance, sumLedgerBalances, "Vault insolvent after batch");
        }
    }
    
    /**
     * @notice INVARIANT: Batch size never exceeds MAX_BATCH_SIZE
     */
    function invariant_batchSizeWithinLimits() public view {
        assertLe(handler.ghost_maxBatchSizeUsed(), batcher.MAX_BATCH_SIZE());
        assertLe(handler.ghost_maxAtomicBatchSizeUsed(), batcher.MAX_BATCH_SIZE());
    }
    
    /**
     * @notice INVARIANT: VERSION constant is correct
     */
    function invariant_versionConstant() public view {
        assertEq(batcher.VERSION(), 2);
    }
    
    // ============ Call Summary ============
    
    function invariant_callSummary() public view {
        console.log("=== SeraBatcher Invariant Test Summary ===");
        console.log("Batch Match Calls:", handler.ghost_batchMatchCalls());
        console.log("Atomic Batch Calls:", handler.ghost_atomicBatchCalls());
        console.log("Mixed Batch Calls:", handler.ghost_mixedBatchCalls());
        console.log("Successful Matches:", handler.ghost_successfulMatches());
        console.log("Failed Matches:", handler.ghost_failedMatches());
        console.log("Max Batch Size Used:", handler.ghost_maxBatchSizeUsed());
    }
}
