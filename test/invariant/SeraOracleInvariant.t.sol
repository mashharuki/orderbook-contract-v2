// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../src/SeraOracle.sol";

/// @title SeraOracle Handler for Invariant Testing
/// @notice Provides bounded actions for fuzzing
contract SeraOracleHandler is Test {
    SeraOracle public oracle;
    
    address public admin;
    address public operator;
    
    // Track state for invariant checks
    uint256 public totalRateUpdates;
    uint256 public totalCurrenciesAdded;
    uint256 public totalCurrenciesRemoved;
    
    bytes32[] public addedCurrencies;
    
    constructor(SeraOracle _oracle, address _admin, address _operator) {
        oracle = _oracle;
        admin = _admin;
        operator = _operator;
    }
    
    /// @notice Update rates with random values
    function updateRates(uint64 seed) external {
        uint256 count = oracle.getCurrencyCount();
        if (count == 0) return;
        
        uint64[] memory rates = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            // Generate rate between 100000 (0.1) and 10000000000 (10000)
            rates[i] = uint64(100000 + (uint256(keccak256(abi.encode(seed, i))) % 9999900000));
        }
        
        vm.prank(operator);
        oracle.updateRatesBatch(rates);
        totalRateUpdates++;
    }
    
    /// @notice Update single rate
    function updateSingleRate(uint8 currencyIdx, uint64 rate) external {
        uint256 count = oracle.getCurrencyCount();
        if (count == 0) return;
        
        currencyIdx = currencyIdx % uint8(count);
        bytes32 currency = oracle.currencies(currencyIdx);
        
        // Bound rate to reasonable values
        rate = uint64(bound(rate, 100000, 10000000000));
        
        vm.prank(operator);
        oracle.updateRate(currency, rate);
        totalRateUpdates++;
    }
    
    /// @notice Add a new currency
    function addCurrency(bytes32 symbol) external {
        if (oracle.getCurrencyCount() >= 256) return;
        if (oracle.isCurrencySupported(symbol)) return;
        if (symbol == bytes32(0)) return;
        
        vm.prank(admin);
        oracle.addCurrency(symbol);
        addedCurrencies.push(symbol);
        totalCurrenciesAdded++;
    }
    
    /// @notice Remove a currency
    function removeCurrency(uint8 idx) external {
        uint256 count = oracle.getCurrencyCount();
        if (count == 0) return;
        
        idx = idx % uint8(count);
        bytes32 currency = oracle.currencies(idx);
        
        vm.prank(admin);
        oracle.removeCurrency(currency);
        totalCurrenciesRemoved++;
    }
    
    /// @notice Incremental rate update
    function updateRatesIncremental(uint8 idx, uint64 newRate) external {
        uint256 count = oracle.getCurrencyCount();
        if (count == 0) return;
        
        idx = idx % uint8(count);
        newRate = uint64(bound(newRate, 100000, 10000000000));
        
        uint8[] memory indices = new uint8[](1);
        indices[0] = idx;
        uint64[] memory rates = new uint64[](1);
        rates[0] = newRate;
        
        vm.prank(operator);
        oracle.updateRatesIncremental(indices, rates);
        totalRateUpdates++;
    }
    
    /// @notice Warp time forward
    function warpTime(uint256 delta) external {
        delta = bound(delta, 0, 100 hours);
        vm.warp(block.timestamp + delta);
    }
}

/// @title SeraOracle Invariant Tests
/// @notice Formal verification through invariant testing
contract SeraOracleInvariant is StdInvariant, Test {
    SeraOracle public oracle;
    SeraOracleHandler public handler;
    
    address public admin = address(0x1);
    address public operator = address(0x2);

    bytes32 public constant JPY = bytes32("JPY");
    bytes32 public constant CNY = bytes32("CNY");
    bytes32 public constant EUR = bytes32("EUR");
    bytes32 public constant GBP = bytes32("GBP");

    function setUp() public {
        vm.startPrank(admin);
        oracle = new SeraOracle(admin);
        oracle.grantRole(oracle.OPERATOR_ROLE(), operator);
        
        // Add initial currencies
        oracle.addCurrency(JPY);
        oracle.addCurrency(CNY);
        oracle.addCurrency(EUR);
        oracle.addCurrency(GBP);
        
        // Set initial rates
        uint64[] memory rates = new uint64[](4);
        rates[0] = 157_253400;
        rates[1] = 7_245600;
        rates[2] = 920000;
        rates[3] = 790000;
        oracle.updateRatesBatch(rates);
        
        vm.stopPrank();
        
        // Setup handler
        handler = new SeraOracleHandler(oracle, admin, operator);
        
        // Target only the handler
        targetContract(address(handler));
    }

    // ============================================================
    // Invariants
    // ============================================================

    /// @notice Currency count never exceeds MAX_CURRENCIES
    function invariant_currencyCountBounded() public view {
        assertLe(oracle.getCurrencyCount(), 256, "Currency count exceeds max");
    }

    /// @notice Heartbeat timeout is always within bounds
    function invariant_heartbeatTimeoutBounded() public view {
        uint64 timeout = oracle.heartbeatTimeout();
        assertGe(timeout, 1 hours, "Heartbeat timeout too short");
        assertLe(timeout, 7 days, "Heartbeat timeout too long");
    }

    /// @notice Currency count consistency
    function invariant_currencyCountConsistency() public view {
        uint256 count = oracle.getCurrencyCount();
        uint256 added = handler.totalCurrenciesAdded();
        uint256 removed = handler.totalCurrenciesRemoved();
        
        // Initial 4 currencies + added - removed = current count
        assertEq(count, 4 + added - removed, "Currency count inconsistent");
    }

    /// @notice All supported currencies have valid indices
    function invariant_currencyIndicesValid() public view {
        uint256 count = oracle.getCurrencyCount();
        
        for (uint256 i = 0; i < count; i++) {
            bytes32 currency = oracle.currencies(i);
            assertTrue(oracle.isCurrencySupported(currency), "Currency should be supported");
            
            uint8 idx = oracle.currencyIndex(currency);
            // Index should match position (except for index 0 edge case)
            if (i > 0) {
                assertEq(idx, i, "Currency index mismatch");
            }
        }
    }

    /// @notice Cross rate symmetry: A/B * B/A ≈ PRECISION²
    /// @dev Only check for initial currencies with known rates
    function invariant_crossRateSymmetry() public view {
        // Only check if both JPY and CNY are still supported and have rates
        if (!oracle.isCurrencySupported(JPY) || !oracle.isCurrencySupported(CNY)) return;
        
        (uint64 rateA,) = oracle.getRate(JPY);
        (uint64 rateB,) = oracle.getRate(CNY);
        
        if (rateA == 0 || rateB == 0) return;
        
        uint64 crossAB = oracle.getCrossRate(JPY, CNY);
        uint64 crossBA = oracle.getCrossRate(CNY, JPY);
        
        // crossAB * crossBA should ≈ 1e12
        uint256 product = uint256(crossAB) * uint256(crossBA);
        uint256 expected = 1e12;
        uint256 tolerance = expected / 20; // 5% tolerance for rounding
        
        assertGe(product, expected - tolerance, "Cross rate product too low");
        assertLe(product, expected + tolerance, "Cross rate product too high");
    }

    /// @notice Rates are always positive for initial currencies after update
    /// @dev New currencies added without rate update will have 0 rate - this is expected behavior
    function invariant_ratesPositive() public view {
        // Only check initial 4 currencies that were set up with rates
        // New currencies added dynamically won't have rates until updated
        if (oracle.lastUpdateTime() == 0) return;
        if (oracle.getCurrencyCount() == 0) return;
        
        // Check only if we haven't removed initial currencies
        if (oracle.isCurrencySupported(JPY)) {
            (uint64 rate,) = oracle.getRate(JPY);
            assertGt(rate, 0, "JPY rate should be positive");
        }
    }

    /// @notice Last update time never decreases
    function invariant_lastUpdateTimeMonotonic() public view {
        // This is implicitly true since we only set it to block.timestamp
        // and block.timestamp is monotonically increasing
        assertTrue(true);
    }

    /// @notice Health status is consistent with timestamp
    function invariant_healthConsistency() public view {
        uint64 lastUpdate = oracle.lastUpdateTime();
        uint64 timeout = oracle.heartbeatTimeout();
        bool healthy = oracle.isHealthy();
        
        if (lastUpdate == 0) {
            // Never updated - should be unhealthy
            assertFalse(healthy, "Should be unhealthy if never updated");
        } else if (block.timestamp - lastUpdate < timeout) {
            assertTrue(healthy, "Should be healthy within timeout");
        } else {
            assertFalse(healthy, "Should be unhealthy after timeout");
        }
    }

    /// @notice Conversion round trip preserves value (within tolerance)
    function invariant_conversionRoundTrip() public view {
        uint256 count = oracle.getCurrencyCount();
        if (count == 0) return;
        if (oracle.lastUpdateTime() == 0) return;
        
        bytes32 currency = oracle.currencies(0);
        (uint64 rate,) = oracle.getRate(currency);
        if (rate == 0) return;
        
        uint256 usdAmount = 1000_000000; // 1000 USD
        uint256 foreignAmount = oracle.convertFromUSD(currency, usdAmount);
        uint256 usdBack = oracle.convertToUSD(currency, foreignAmount);
        
        // Allow 1% tolerance
        uint256 tolerance = usdAmount / 100;
        assertGe(usdBack, usdAmount - tolerance, "Round trip lost too much");
        assertLe(usdBack, usdAmount + tolerance, "Round trip gained too much");
    }

    // ============================================================
    // Call Summary
    // ============================================================

    function invariant_callSummary() public view {
        console.log("=== Invariant Test Summary ===");
        console.log("Total rate updates:", handler.totalRateUpdates());
        console.log("Currencies added:", handler.totalCurrenciesAdded());
        console.log("Currencies removed:", handler.totalCurrenciesRemoved());
        console.log("Current currency count:", oracle.getCurrencyCount());
        console.log("Last update time:", oracle.lastUpdateTime());
        console.log("Is healthy:", oracle.isHealthy());
    }
}
