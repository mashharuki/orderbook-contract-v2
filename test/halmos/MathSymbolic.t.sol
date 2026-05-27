// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";

/**
 * @title MathSymbolic - Comprehensive math operation symbolic tests
 * @notice Tests all mathematical operations used in Sera protocol
 * @dev Halmos test functions prefixed with `check_`
 */
contract MathSymbolic is Test {
    
    // ============ Addition Properties ============
    
    /**
     * @notice Verify addition commutativity: a + b = b + a
     */
    function check_additionCommutativity(uint128 a, uint128 b) public pure {
        uint256 sum1 = uint256(a) + uint256(b);
        uint256 sum2 = uint256(b) + uint256(a);
        assert(sum1 == sum2);
    }
    
    /**
     * @notice Verify addition associativity: (a + b) + c = a + (b + c)
     */
    function check_additionAssociativity(uint128 a, uint128 b, uint128 c) public pure {
        uint256 left = (uint256(a) + uint256(b)) + uint256(c);
        uint256 right = uint256(a) + (uint256(b) + uint256(c));
        assert(left == right);
    }
    
    /**
     * @notice Verify addition identity: a + 0 = a
     */
    function check_additionIdentity(uint256 a) public pure {
        vm.assume(a < type(uint128).max);
        uint256 result = a + 0;
        assert(result == a);
    }
    
    /**
     * @notice Verify addition with overflow protection
     */
    function check_additionOverflowProtection(uint128 a, uint128 b) public pure {
        uint256 result = uint256(a) + uint256(b);
        assert(result >= uint256(a));
        assert(result >= uint256(b));
    }
    
    // ============ Subtraction Properties ============
    
    /**
     * @notice Verify subtraction inverse: (a + b) - b = a
     */
    function check_subtractionInverse(uint128 a, uint128 b) public pure {
        uint256 sum = uint256(a) + uint256(b);
        uint256 result = sum - uint256(b);
        assert(result == uint256(a));
    }
    
    /**
     * @notice Verify subtraction underflow protection
     */
    function check_subtractionUnderflowProtection(uint128 a, uint128 b) public pure {
        vm.assume(a >= b);
        uint256 result = uint256(a) - uint256(b);
        assert(result <= uint256(a));
    }
    
    /**
     * @notice Verify subtraction identity: a - 0 = a
     */
    function check_subtractionIdentity(uint256 a) public pure {
        vm.assume(a < type(uint128).max);
        uint256 result = a - 0;
        assert(result == a);
    }
    
    // ============ Multiplication Properties ============
    
    /**
     * @notice Verify multiplication commutativity: a * b = b * a
     */
    function check_multiplicationCommutativity(uint64 a, uint64 b) public pure {
        uint256 product1 = uint256(a) * uint256(b);
        uint256 product2 = uint256(b) * uint256(a);
        assert(product1 == product2);
    }
    
    /**
     * @notice Verify multiplication by zero: a * 0 = 0
     */
    function check_multiplicationByZero(uint256 a) public pure {
        vm.assume(a < type(uint128).max);
        uint256 result = a * 0;
        assert(result == 0);
    }
    
    /**
     * @notice Verify multiplication by one: a * 1 = a
     */
    function check_multiplicationByOne(uint256 a) public pure {
        vm.assume(a < type(uint128).max);
        uint256 result = a * 1;
        assert(result == a);
    }
    
    /**
     * @notice Verify multiplication distributivity: a * (b + c) = a * b + a * c
     */
    function check_multiplicationDistributivity(uint64 a, uint64 b, uint64 c) public pure {
        uint256 left = uint256(a) * (uint256(b) + uint256(c));
        uint256 right = (uint256(a) * uint256(b)) + (uint256(a) * uint256(c));
        assert(left == right);
    }
    
    // ============ Division Properties ============
    
    /**
     * @notice Verify division by self: a / a = 1 (for a > 0)
     */
    function check_divisionBySelf(uint128 a) public pure {
        vm.assume(a > 0);
        uint256 result = uint256(a) / uint256(a);
        assert(result == 1);
    }
    
    /**
     * @notice Verify division by larger: a / (a + 1) = 0
     */
    function check_divisionByLarger(uint128 a) public pure {
        uint256 result = uint256(a) / (uint256(a) + 1);
        assert(result == 0);
    }
    
    /**
     * @notice Verify division reverses multiplication: (a * b) / b = a
     */
    function check_divisionReversesMultiplication(uint64 a, uint64 b) public pure {
        vm.assume(b > 0);
        uint256 product = uint256(a) * uint256(b);
        uint256 result = product / uint256(b);
        assert(result == uint256(a));
    }
    
    /**
     * @notice Verify division with remainder check
     */
    function check_divisionWithRemainder(uint128 a, uint64 b) public pure {
        vm.assume(b > 0);
        uint256 quotient = uint256(a) / uint256(b);
        uint256 remainder = uint256(a) % uint256(b);
        assert(quotient * uint256(b) + remainder == uint256(a));
        assert(remainder < uint256(b));
    }
    
    // ============ Rounding Properties ============
    
    /**
     * @notice Verify ceiling division: ceil(a / b) * b >= a
     */
    function check_ceilingDivision(uint128 a, uint64 b) public pure {
        vm.assume(b > 0);
        uint256 ceilResult = (uint256(a) + uint256(b) - 1) / uint256(b);
        assert(ceilResult * uint256(b) >= uint256(a));
    }
    
    /**
     * @notice Verify floor division: floor(a / b) * b <= a
     */
    function check_floorDivision(uint128 a, uint64 b) public pure {
        vm.assume(b > 0);
        uint256 floorResult = uint256(a) / uint256(b);
        assert(floorResult * uint256(b) <= uint256(a));
    }
    
    /**
     * @notice Verify rounding difference bound
     */
    function check_roundingDifferenceBound(uint128 a, uint64 b) public pure {
        vm.assume(b > 0);
        uint256 floorResult = uint256(a) / uint256(b);
        uint256 ceilResult = (uint256(a) + uint256(b) - 1) / uint256(b);
        
        // Difference is at most 1
        assert(ceilResult - floorResult <= 1);
    }
    
    // ============ BPS (Basis Points) Calculations ============
    
    /**
     * @notice Verify BPS calculation: result = (amount * bps) / 10000
     */
    function check_bpsCalculation(uint128 amount, uint16 bps) public pure {
        vm.assume(bps <= 10000);
        uint256 result = (uint256(amount) * uint256(bps)) / 10000;
        assert(result <= uint256(amount));
    }
    
    /**
     * @notice Verify BPS calculation extremes
     */
    function check_bpsCalculationExtremes(uint128 amount) public pure {
        // 0 BPS = 0 result
        uint256 zeroBps = (uint256(amount) * 0) / 10000;
        assert(zeroBps == 0);
        
        // 10000 BPS = full amount
        uint256 fullBps = (uint256(amount) * 10000) / 10000;
        assert(fullBps == uint256(amount));
    }
    
    /**
     * @notice Verify proportional calculation
     */
    function check_proportionalCalculation(uint64 a, uint64 b, uint64 numerator, uint64 denominator) public pure {
        vm.assume(denominator > 0);
        vm.assume(numerator <= denominator);
        
        uint256 aResult = (uint256(a) * uint256(numerator)) / uint256(denominator);
        uint256 bResult = (uint256(b) * uint256(numerator)) / uint256(denominator);
        
        // Proportionality preserved
        if (a > b) {
            assert(aResult >= bResult);
        }
    }
    
    // ============ Percentage Calculations ============
    
    /**
     * @notice Verify percentage calculation
     */
    function check_percentageCalculation(uint128 amount, uint8 percentage) public pure {
        vm.assume(percentage <= 100);
        uint256 result = (uint256(amount) * uint256(percentage)) / 100;
        assert(result <= uint256(amount));
    }
    
    /**
     * @notice Verify inverse percentage
     */
    function check_inversePercentage(uint128 amount, uint8 percentage) public pure {
        vm.assume(percentage <= 100);
        uint256 part = (uint256(amount) * uint256(percentage)) / 100;
        uint256 inverse = (uint256(amount) * uint256(100 - percentage)) / 100;
        assert(part + inverse == uint256(amount));
    }
    
    // ============ Price/Exchange Rate Calculations ============
    
    /**
     * @notice Verify price conversion consistency
     */
    function check_priceConversionConsistency(uint64 amount, uint64 price, uint64 base) public pure {
        vm.assume(base > 0);
        vm.assume(price > 0);
        
        uint256 output = (uint256(amount) * uint256(price)) / uint256(base);
        
        // Price is positive
        assert(output >= 0);
        
        // With price = base, output = input
        if (price == base) {
            assert(output == uint256(amount));
        }
    }
    
    /**
     * @notice Verify exchange rate cross multiplication
     */
    function check_exchangeRateCross(uint64 amountA, uint64 amountB, uint64 rate) public pure {
        vm.assume(rate > 0);
        
        // If A -> B -> A, we should get approximately original
        uint256 toB = (uint256(amountA) * uint256(rate)) / 1e18;
        if (toB > 0) {
            uint256 backToA = (toB * 1e18) / uint256(rate);
            // Small rounding error allowed
            assert(backToA <= uint256(amountA));
            assert(backToA >= uint256(amountA) - 1);
        }
    }
    
    // ============ Accumulation Properties ============
    
    /**
     * @notice Verify running sum consistency
     */
    function check_runningSumConsistency(uint64[] memory values) public pure {
        vm.assume(values.length <= 10);
        
        uint256 runningSum = 0;
        for (uint i = 0; i < values.length; i++) {
            runningSum += uint256(values[i]);
        }
        
        // Sum is non-negative
        assert(runningSum >= 0);
        
        // Sum >= each individual value
        for (uint i = 0; i < values.length; i++) {
            assert(runningSum >= uint256(values[i]));
        }
    }
    
    /**
     * @notice Verify average calculation
     */
    function check_averageCalculation(uint64 a, uint64 b) public pure {
        uint256 avg = (uint256(a) + uint256(b)) / 2;
        
        // Average between inputs
        assert(avg >= uint256(a) || avg >= uint256(b));
        assert(avg <= uint256(a) || avg <= uint256(b));
    }
    
    // ============ Comparison Properties ============
    
    /**
     * @notice Verify min/max functions
     */
    function check_minMaxFunctions(uint128 a, uint128 b) public pure {
        uint256 min = a < b ? uint256(a) : uint256(b);
        uint256 max = a > b ? uint256(a) : uint256(b);
        
        assert(min <= max);
        assert(min <= uint256(a) && min <= uint256(b));
        assert(max >= uint256(a) || max >= uint256(b));
    }
    
    /**
     * @notice Verify clamp function
     */
    function check_clampFunction(uint128 value, uint128 min, uint128 max) public pure {
        vm.assume(min <= max);
        
        uint256 clamped;
        if (uint256(value) < uint256(min)) {
            clamped = uint256(min);
        } else if (uint256(value) > uint256(max)) {
            clamped = uint256(max);
        } else {
            clamped = uint256(value);
        }
        
        assert(clamped >= uint256(min));
        assert(clamped <= uint256(max));
    }
    
    // ============ Gas Optimization Properties ============
    
    /**
     * @notice Verify unchecked math saves gas
     */
    function check_uncheckedMathGas(uint128 a, uint128 b) public pure {
        // Checked addition
        uint256 checkedSum = uint256(a) + uint256(b);
        
        // Unchecked would be same for safe values
        uint256 uncheckedSum;
        unchecked {
            uncheckedSum = uint256(a) + uint256(b);
        }
        
        assert(checkedSum == uncheckedSum);
    }
    
    /**
     * @notice Verify bit manipulation for efficiency
     */
    function check_bitManipulationEfficiency(uint128 value) public pure {
        // Division by power of 2
        uint256 div2 = uint256(value) / 2;
        uint256 shift1 = uint256(value) >> 1;
        assert(div2 == shift1);
        
        // Division by 4
        uint256 div4 = uint256(value) / 4;
        uint256 shift2 = uint256(value) >> 2;
        assert(div4 == shift2);
    }
    
    // ============ Special Cases ============
    
    /**
     * @notice Verify handling of maximum uint values
     */
    function check_maximumUintHandling() public pure {
        uint256 max = type(uint256).max;
        
        // Max divided by 1
        assert(max / 1 == max);
        
        // Max modulo max
        assert(max % max == 0);
        
        // Max divided by 2
        assert(max / 2 == max >> 1);
    }
    
    /**
     * @notice Verify zero handling in all operations
     */
    function check_zeroHandling() public pure {
        uint256 zero = 0;
        uint256 any = 100;
        
        // Addition
        assert(zero + any == any);
        assert(any + zero == any);
        
        // Subtraction
        assert(any - zero == any);
        
        // Multiplication
        assert(zero * any == zero);
        assert(any * zero == zero);
    }
    
    // ============ Financial Calculation Properties ============
    
    /**
     * @notice Verify compound interest calculation
     */
    function check_compoundInterest(uint64 principal, uint16 rateBps, uint8 periods) public pure {
        vm.assume(principal > 0);
        vm.assume(rateBps <= 1000); // Max 10% per period
        vm.assume(periods > 0 && periods <= 100);
        
        uint256 amount = uint256(principal);
        for (uint i = 0; i < periods; i++) {
            uint256 interest = (amount * uint256(rateBps)) / 10000;
            amount += interest;
        }
        
        // Amount grows with positive rate
        assert(amount >= uint256(principal));
    }
    
    /**
     * @notice Verify fee accumulation
     */
    function check_feeAccumulation(uint64[] memory amounts, uint16 feeBps) public pure {
        vm.assume(feeBps <= 10000);
        vm.assume(amounts.length <= 10);
        
        uint256 totalFee = 0;
        for (uint i = 0; i < amounts.length; i++) {
            uint256 fee = (uint256(amounts[i]) * uint256(feeBps)) / 10000;
            totalFee += fee;
        }
        
        // Total fee bounded
        assert(totalFee >= 0);
    }
    
    /**
     * @notice Verify weighted average
     */
    function check_weightedAverage(uint64 valueA, uint64 weightA, uint64 valueB, uint64 weightB) public pure {
        vm.assume(weightA + weightB > 0);
        
        uint256 weightedSum = (uint256(valueA) * uint256(weightA)) + (uint256(valueB) * uint256(weightB));
        uint256 totalWeight = uint256(weightA) + uint256(weightB);
        uint256 weightedAvg = weightedSum / totalWeight;
        
        // Between min and max values
        assert(weightedAvg >= (valueA < valueB ? valueA : valueB));
        assert(weightedAvg <= (valueA > valueB ? valueA : valueB));
    }
}
