// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/SeraOracle.sol";

/// @title SeraOracle Formal Verification Tests
/// @notice Symbolic execution tests using Halmos
/// @dev Run with: halmos --contract SeraOracleFormal
contract SeraOracleFormal is Test {
    SeraOracle public oracle;
    
    address public admin = address(0x1);
    address public operator = address(0x2);
    address public attacker = address(0x3);

    bytes32 public constant JPY = bytes32("JPY");
    bytes32 public constant CNY = bytes32("CNY");
    bytes32 public constant EUR = bytes32("EUR");

    function setUp() public {
        vm.startPrank(admin);
        oracle = new SeraOracle(admin);
        oracle.grantRole(oracle.OPERATOR_ROLE(), operator);
        
        // Add test currencies
        oracle.addCurrency(JPY);
        oracle.addCurrency(CNY);
        oracle.addCurrency(EUR);
        vm.stopPrank();
    }

    // ============================================================
    // Access Control Verification
    // ============================================================

    /// @notice Verify only operator can update rates
    function check_onlyOperatorCanUpdateRates(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        // Attacker should fail
        vm.prank(attacker);
        try oracle.updateRatesBatch(rates) {
            assert(false); // Should not reach here
        } catch {
            // Expected to revert
        }

        // Operator should succeed
        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        
        (uint64 actualRate,) = oracle.getRate(JPY);
        assert(actualRate == rate0);
    }

    /// @notice Verify only admin can add currency
    function check_onlyAdminCanAddCurrency(bytes32 symbol) public {
        vm.assume(symbol != bytes32(0));
        vm.assume(!oracle.isCurrencySupported(symbol));

        // Attacker should fail
        vm.prank(attacker);
        try oracle.addCurrency(symbol) {
            assert(false);
        } catch {}

        // Operator should also fail (not admin)
        vm.prank(operator);
        try oracle.addCurrency(symbol) {
            assert(false);
        } catch {}

        // Admin should succeed
        uint256 countBefore = oracle.getCurrencyCount();
        vm.prank(admin);
        oracle.addCurrency(symbol);
        
        assert(oracle.getCurrencyCount() == countBefore + 1);
        assert(oracle.isCurrencySupported(symbol));
    }

    /// @notice Verify only admin can remove currency
    function check_onlyAdminCanRemoveCurrency() public {
        // Attacker should fail
        vm.prank(attacker);
        try oracle.removeCurrency(EUR) {
            assert(false);
        } catch {}

        // Admin should succeed
        uint256 countBefore = oracle.getCurrencyCount();
        vm.prank(admin);
        oracle.removeCurrency(EUR);
        
        assert(oracle.getCurrencyCount() == countBefore - 1);
        assert(!oracle.isCurrencySupported(EUR));
    }

    // ============================================================
    // Rate Integrity Verification
    // ============================================================

    /// @notice Verify rate update changes lastUpdateTime
    function check_rateUpdateChangesTimestamp(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        uint64 timeBefore = oracle.lastUpdateTime();
        
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        
        uint64 timeAfter = oracle.lastUpdateTime();
        
        assert(timeAfter > timeBefore);
        assert(timeAfter == uint64(block.timestamp));
    }

    /// @notice Verify rate update preserves currency count
    function check_rateUpdatePreservesCurrencyCount(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        uint256 countBefore = oracle.getCurrencyCount();
        
        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        
        assert(oracle.getCurrencyCount() == countBefore);
    }

    /// @notice Verify rates are stored correctly
    function check_ratesStoredCorrectly(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        
        (uint64 jpyRate,) = oracle.getRate(JPY);
        (uint64 cnyRate,) = oracle.getRate(CNY);
        (uint64 eurRate,) = oracle.getRate(EUR);
        
        assert(jpyRate == rate0);
        assert(cnyRate == rate1);
        assert(eurRate == rate2);
    }

    // ============================================================
    // Currency Management Verification
    // ============================================================

    /// @notice Verify cannot add duplicate currency
    function check_cannotAddDuplicateCurrency() public {
        vm.prank(admin);
        try oracle.addCurrency(JPY) {
            assert(false); // JPY already exists
        } catch {}
    }

    /// @notice Verify cannot remove unsupported currency
    function check_cannotRemoveUnsupportedCurrency(bytes32 symbol) public {
        vm.assume(!oracle.isCurrencySupported(symbol));
        
        vm.prank(admin);
        try oracle.removeCurrency(symbol) {
            assert(false);
        } catch {}
    }

    /// @notice Verify currency count bounds
    function check_currencyCountBounded() public view {
        assert(oracle.getCurrencyCount() <= 256);
    }

    // ============================================================
    // Cross Rate Calculation Verification
    // ============================================================

    /// @notice Verify cross rate calculation is correct
    function check_crossRateCalculation(uint64 jpyRate, uint64 cnyRate) public {
        vm.assume(jpyRate > 0 && jpyRate < type(uint64).max / 1e6);
        vm.assume(cnyRate > 0 && cnyRate < type(uint64).max / 1e6);

        uint64[] memory rates = new uint64[](3);
        rates[0] = jpyRate;
        rates[1] = cnyRate;
        rates[2] = 920000; // EUR

        vm.prank(operator);
        oracle.updateRatesBatch(rates);

        // CNY/JPY = USD/JPY / USD/CNY
        uint64 crossRate = oracle.getCrossRate(CNY, JPY);
        
        // Manual calculation
        uint256 expected = (uint256(jpyRate) * 1e6) / cnyRate;
        
        // Allow small rounding difference
        assert(crossRate == uint64(expected) || crossRate == uint64(expected) + 1 || crossRate == uint64(expected) - 1);
    }

    /// @notice Verify cross rate symmetry (A/B * B/A ≈ 1)
    function check_crossRateSymmetry(uint64 jpyRate, uint64 cnyRate) public {
        vm.assume(jpyRate > 1e6 && jpyRate < 1e12); // Reasonable range
        vm.assume(cnyRate > 1e6 && cnyRate < 1e12);

        uint64[] memory rates = new uint64[](3);
        rates[0] = jpyRate;
        rates[1] = cnyRate;
        rates[2] = 920000;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);

        uint64 cnyToJpy = oracle.getCrossRate(CNY, JPY);
        uint64 jpyToCny = oracle.getCrossRate(JPY, CNY);

        // cnyToJpy * jpyToCny should ≈ 1e12 (PRECISION²)
        uint256 product = uint256(cnyToJpy) * uint256(jpyToCny);
        uint256 expected = 1e12;
        
        // Allow 1% tolerance
        uint256 tolerance = expected / 100;
        assert(product >= expected - tolerance && product <= expected + tolerance);
    }

    // ============================================================
    // Conversion Verification
    // ============================================================

    /// @notice Verify USD conversion round trip
    function check_conversionRoundTrip(uint64 rate, uint64 usdAmount) public {
        vm.assume(rate > 0 && rate < type(uint64).max / 1e6);
        vm.assume(usdAmount > 1e6 && usdAmount < type(uint64).max / rate);

        uint64[] memory rates = new uint64[](3);
        rates[0] = rate;
        rates[1] = 7_245600;
        rates[2] = 920000;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);

        // USD -> JPY -> USD
        uint256 jpyAmount = oracle.convertFromUSD(JPY, usdAmount);
        uint256 usdBack = oracle.convertToUSD(JPY, jpyAmount);

        // Allow 1% tolerance for rounding
        uint256 tolerance = usdAmount / 100;
        if (tolerance == 0) tolerance = 1;
        
        assert(usdBack >= usdAmount - tolerance && usdBack <= usdAmount + tolerance);
    }

    // ============================================================
    // Heartbeat Verification
    // ============================================================

    /// @notice Verify oracle is healthy after update
    function check_healthyAfterUpdate(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);

        assert(oracle.isHealthy());
    }

    /// @notice Verify oracle becomes unhealthy after timeout
    function check_unhealthyAfterTimeout(uint64 rate0, uint64 rate1, uint64 rate2) public {
        uint64[] memory rates = new uint64[](3);
        rates[0] = rate0;
        rates[1] = rate1;
        rates[2] = rate2;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        
        assert(oracle.isHealthy());

        // Fast forward past heartbeat timeout
        vm.warp(block.timestamp + 49 hours);
        
        assert(!oracle.isHealthy());
    }

    /// @notice Verify heartbeat timeout bounds
    function check_heartbeatTimeoutBounds(uint64 newTimeout) public {
        vm.prank(admin);
        
        if (newTimeout < 1 hours || newTimeout > 7 days) {
            try oracle.setHeartbeatTimeout(newTimeout) {
                assert(false); // Should revert
            } catch {}
        } else {
            oracle.setHeartbeatTimeout(newTimeout);
            assert(oracle.heartbeatTimeout() == newTimeout);
        }
    }

    // ============================================================
    // Invariant: No Overflow
    // ============================================================

    /// @notice Verify no overflow in cross rate calculation
    function check_noOverflowInCrossRate(uint64 baseRate, uint64 quoteRate) public {
        vm.assume(baseRate > 0);
        vm.assume(quoteRate > 0);
        vm.assume(quoteRate <= type(uint64).max / 1e6); // Prevent overflow

        uint64[] memory rates = new uint64[](3);
        rates[0] = quoteRate; // JPY (quote)
        rates[1] = baseRate;  // CNY (base)
        rates[2] = 920000;

        vm.prank(operator);
        oracle.updateRatesBatch(rates);

        // Should not revert
        uint64 crossRate = oracle.getCrossRate(CNY, JPY);
        
        // Verify result is reasonable
        assert(crossRate > 0);
    }

    // ============================================================
    // Incremental Update Verification
    // ============================================================

    /// @notice Verify incremental update only changes specified indices
    function check_incrementalUpdateSelectivity(uint64 newJpyRate) public {
        // Set initial rates
        uint64[] memory initialRates = new uint64[](3);
        initialRates[0] = 157_253400;
        initialRates[1] = 7_245600;
        initialRates[2] = 920000;

        vm.prank(operator);
        oracle.updateRatesBatch(initialRates);

        // Get initial values
        (uint64 cnyBefore,) = oracle.getRate(CNY);
        (uint64 eurBefore,) = oracle.getRate(EUR);

        // Update only JPY
        uint8[] memory indices = new uint8[](1);
        indices[0] = 0;
        uint64[] memory newRates = new uint64[](1);
        newRates[0] = newJpyRate;

        vm.prank(operator);
        oracle.updateRatesIncremental(indices, newRates);

        // Verify JPY changed
        (uint64 jpyAfter,) = oracle.getRate(JPY);
        assert(jpyAfter == newJpyRate);

        // Verify others unchanged
        (uint64 cnyAfter,) = oracle.getRate(CNY);
        (uint64 eurAfter,) = oracle.getRate(EUR);
        assert(cnyAfter == cnyBefore);
        assert(eurAfter == eurBefore);
    }
}
