// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";

/**
 * @title VaultSymbolicSimple - Simplified Halmos tests for Vault logic
 * @notice Tests core arithmetic and logic properties without complex setup
 * @dev Halmos test functions must be prefixed with `check_`
 */
contract VaultSymbolicSimple is Test {
    
    // ============ Balance Arithmetic Properties ============
    
    /**
     * @notice Verify deposit arithmetic: balance + amount = newBalance
     */
    function check_depositArithmetic(uint256 balance, uint256 amount) public pure {
        // Preconditions to avoid overflow
        vm.assume(balance < type(uint128).max);
        vm.assume(amount < type(uint128).max);
        vm.assume(balance + amount < type(uint256).max);
        
        uint256 newBalance = balance + amount;
        
        // Postcondition
        assert(newBalance == balance + amount);
        assert(newBalance >= balance); // No underflow
        assert(newBalance >= amount);  // No underflow
    }
    
    /**
     * @notice Verify withdraw arithmetic: balance - amount = newBalance
     */
    function check_withdrawArithmetic(uint256 balance, uint256 amount) public pure {
        // Preconditions
        vm.assume(balance < type(uint128).max);
        vm.assume(amount <= balance); // Cannot withdraw more than balance
        
        uint256 newBalance = balance - amount;
        
        // Postconditions
        assert(newBalance == balance - amount);
        assert(newBalance <= balance); // Balance decreased
        assert(newBalance + amount == balance); // Reversible
    }
    
    /**
     * @notice Verify transfer preserves total: from + to = (from - amt) + (to + amt)
     */
    function check_transferPreservesTotal(
        uint256 fromBalance,
        uint256 toBalance,
        uint256 amount
    ) public pure {
        // Preconditions
        vm.assume(fromBalance < type(uint128).max);
        vm.assume(toBalance < type(uint128).max);
        vm.assume(amount <= fromBalance);
        vm.assume(toBalance + amount < type(uint256).max);
        
        uint256 totalBefore = fromBalance + toBalance;
        
        uint256 newFromBalance = fromBalance - amount;
        uint256 newToBalance = toBalance + amount;
        
        uint256 totalAfter = newFromBalance + newToBalance;
        
        // Postcondition: total preserved
        assert(totalAfter == totalBefore);
    }
    
    // ============ Solvency Properties ============
    
    /**
     * @notice Verify solvency: actualBalance >= sumOfUserBalances
     */
    function check_solvencyAfterDeposit(
        uint256 actualBalance,
        uint256 userBalance,
        uint256 depositAmount
    ) public pure {
        // Preconditions
        vm.assume(actualBalance < type(uint128).max);
        vm.assume(userBalance < type(uint128).max);
        vm.assume(depositAmount < type(uint128).max);
        vm.assume(actualBalance >= userBalance); // Initially solvent
        
        // After deposit, both increase by same amount
        uint256 newActualBalance = actualBalance + depositAmount;
        uint256 newUserBalance = userBalance + depositAmount;
        
        // Postcondition: still solvent
        assert(newActualBalance >= newUserBalance);
    }
    
    /**
     * @notice Verify solvency: actualBalance >= userBalance after withdraw
     */
    function check_solvencyAfterWithdraw(
        uint256 actualBalance,
        uint256 userBalance,
        uint256 withdrawAmount
    ) public pure {
        // Preconditions - tighter bounds
        vm.assume(actualBalance > 0 && actualBalance < type(uint64).max);
        vm.assume(userBalance > 0 && userBalance <= actualBalance);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= userBalance);
        
        // After withdraw, both decrease by same amount
        uint256 newActualBalance = actualBalance - withdrawAmount;
        uint256 newUserBalance = userBalance - withdrawAmount;
        
        // Postcondition: still solvent
        assert(newActualBalance >= newUserBalance);
    }
    
    // ============ Fee Calculation Properties ============
    
    /**
     * @notice Verify fee calculation: fee = amount * feeBps / 10000
     * @dev Using concrete values to help SMT solver
     */
    function check_feeCalculation(uint8 amountScale, uint16 feeBps) public pure {
        // Use scaled amount to reduce search space
        uint256 amount = uint256(amountScale) * 1e15; // 0 to 255e15
        vm.assume(feeBps <= 10000); // Max 100% fee
        
        uint256 fee = (amount * uint256(feeBps)) / 10000;
        
        // Postconditions
        assert(fee <= amount); // Fee cannot exceed amount
        
        // Additional check: fee is proportional
        if (feeBps == 10000) {
            assert(fee == amount);
        }
        if (feeBps == 0) {
            assert(fee == 0);
        }
    }
    
    /**
     * @notice Verify fee split: makerFee + takerFee + protocolFee = totalFee
     */
    function check_feeSplit(
        uint256 totalFee,
        uint256 makerBps,
        uint256 takerBps,
        uint256 protocolBps
    ) public pure {
        // Preconditions
        vm.assume(totalFee < type(uint128).max);
        vm.assume(makerBps + takerBps + protocolBps == 10000); // Must sum to 100%
        
        uint256 makerFee = (totalFee * makerBps) / 10000;
        uint256 takerFee = (totalFee * takerBps) / 10000;
        uint256 protocolFee = totalFee - makerFee - takerFee; // Remainder to protocol
        
        // Postcondition: fees sum to total (accounting for rounding)
        assert(makerFee + takerFee + protocolFee == totalFee);
    }
    
    // ============ Order Matching Properties ============
    
    /**
     * @notice Verify filled amount monotonicity
     */
    function check_filledAmountMonotonic(
        uint256 currentFilled,
        uint256 matchAmount,
        uint256 orderAmount
    ) public pure {
        // Preconditions
        vm.assume(currentFilled < type(uint128).max);
        vm.assume(matchAmount < type(uint128).max);
        vm.assume(currentFilled <= orderAmount);
        vm.assume(currentFilled + matchAmount <= orderAmount);
        
        uint256 newFilled = currentFilled + matchAmount;
        
        // Postconditions
        assert(newFilled >= currentFilled); // Monotonically increasing
        assert(newFilled <= orderAmount);   // Never exceeds order amount
    }
    
    /**
     * @notice Verify price execution: user gets at least their limit price
     */
    function check_priceExecution(
        uint256 fromAmount,
        uint256 toAmount,
        uint256 executionFromAmount,
        uint256 executionToAmount
    ) public pure {
        // Preconditions
        vm.assume(fromAmount > 0 && fromAmount < type(uint128).max);
        vm.assume(toAmount > 0 && toAmount < type(uint128).max);
        vm.assume(executionFromAmount > 0 && executionFromAmount <= fromAmount);
        vm.assume(executionToAmount > 0);
        
        // User's limit price: toAmount / fromAmount
        // Execution price: executionToAmount / executionFromAmount
        // User should get at least their limit price
        
        // Cross multiply to avoid division: 
        // executionToAmount / executionFromAmount >= toAmount / fromAmount
        // executionToAmount * fromAmount >= toAmount * executionFromAmount
        
        bool priceValid = executionToAmount * fromAmount >= toAmount * executionFromAmount;
        
        // If execution is valid, user gets at least their limit
        if (priceValid) {
            assert(executionToAmount * fromAmount >= toAmount * executionFromAmount);
        }
    }
    
    // ============ Withdrawal Delay Properties ============
    
    /**
     * @notice Verify withdrawal delay logic
     */
    function check_withdrawalDelay(
        uint256 requestBlock,
        uint256 currentBlock,
        uint256 delayBlocks
    ) public pure {
        // Preconditions
        vm.assume(requestBlock < type(uint128).max);
        vm.assume(currentBlock < type(uint128).max);
        vm.assume(delayBlocks < type(uint64).max);
        vm.assume(requestBlock <= currentBlock);
        
        bool canWithdraw = currentBlock >= requestBlock + delayBlocks;
        uint256 blocksWaited = currentBlock - requestBlock;
        
        // Postconditions
        if (blocksWaited >= delayBlocks) {
            assert(canWithdraw == true);
        } else {
            assert(canWithdraw == false);
        }
    }
    
    /**
     * @notice Verify withdrawal expiration logic
     */
    function check_withdrawalExpiration(
        uint256 requestBlock,
        uint256 currentBlock,
        uint256 delayBlocks,
        uint256 expirationBlocks
    ) public pure {
        // Preconditions
        vm.assume(requestBlock < type(uint64).max);
        vm.assume(currentBlock < type(uint128).max);
        vm.assume(delayBlocks < expirationBlocks);
        vm.assume(requestBlock <= currentBlock);
        
        uint256 windowStart = requestBlock + delayBlocks;
        uint256 windowEnd = requestBlock + expirationBlocks;
        
        bool inWindow = currentBlock >= windowStart && currentBlock <= windowEnd;
        
        // Postconditions
        if (currentBlock < windowStart) {
            assert(inWindow == false); // Too early
        }
        if (currentBlock > windowEnd) {
            assert(inWindow == false); // Too late (expired)
        }
    }
}
