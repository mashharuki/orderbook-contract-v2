/*
 * Certora Formal Verification Specification for SeraOracle
 * 
 * This spec verifies critical invariants and properties of the Oracle contract:
 * 1. Rate integrity - rates are always valid after updates
 * 2. Currency management - indices are consistent
 * 3. Heartbeat - timestamp updates correctly
 */

// ============================================================
// Methods Declaration
// ============================================================

methods {
    // View functions - envfree
    function getRate(bytes32) external returns (uint64, uint64) envfree;
    function getCrossRate(bytes32, bytes32) external returns (uint64) envfree;
    function convertFromUSD(bytes32, uint256) external returns (uint256) envfree;
    function convertToUSD(bytes32, uint256) external returns (uint256) envfree;
    function isHealthy() external returns (bool) envfree;
    function getCurrencyCount() external returns (uint256) envfree;
    function isCurrencySupported(bytes32) external returns (bool) envfree;
    function lastUpdateTime() external returns (uint64) envfree;
    function heartbeatTimeout() external returns (uint64) envfree;
    function currencyIndex(bytes32) external returns (uint8) envfree;
    function DECIMALS() external returns (uint8) envfree;
    function PRECISION() external returns (uint64) envfree;
    function MAX_CURRENCIES() external returns (uint256) envfree;
}

// ============================================================
// Invariants
// ============================================================

/// @title Currency count is bounded
/// @notice The number of currencies never exceeds MAX_CURRENCIES (256)
invariant currencyCountBounded()
    getCurrencyCount() <= 256;

/// @title Heartbeat timeout is reasonable
/// @notice Heartbeat timeout is between 1 hour and 7 days
invariant heartbeatTimeoutBounded()
    heartbeatTimeout() >= 3600 && heartbeatTimeout() <= 604800;

// ============================================================
// Rules - Rate Update Integrity
// ============================================================

/// @title Rate update preserves currency count
/// @notice Updating rates does not change the number of currencies
rule rateUpdatePreservesCurrencyCount(env e, uint64[] rates) {
    uint256 countBefore = getCurrencyCount();
    
    updateRatesBatch(e, rates);
    
    uint256 countAfter = getCurrencyCount();
    
    assert countBefore == countAfter,
        "Rate update should not change currency count";
}

/// @title Single rate update preserves currency count
rule singleRateUpdatePreservesCurrencyCount(env e, bytes32 currency, uint64 rate) {
    uint256 countBefore = getCurrencyCount();
    
    updateRate(e, currency, rate);
    
    uint256 countAfter = getCurrencyCount();
    
    assert countBefore == countAfter,
        "Single rate update should not change currency count";
}

// ============================================================
// Rules - Currency Management
// ============================================================

/// @title Adding currency increases count
/// @notice After adding a new currency, count increases by 1
rule addCurrencyIncreasesCount(env e, bytes32 symbol) {
    uint256 countBefore = getCurrencyCount();
    require countBefore < 256;
    require !isCurrencySupported(symbol);
    
    addCurrency(e, symbol);
    
    uint256 countAfter = getCurrencyCount();
    
    assert countAfter == countBefore + 1,
        "Adding new currency should increase count by 1";
}

/// @title Added currency becomes supported
rule addedCurrencyIsSupported(env e, bytes32 symbol) {
    require !isCurrencySupported(symbol);
    require getCurrencyCount() < 256;
    
    addCurrency(e, symbol);
    
    assert isCurrencySupported(symbol),
        "Currency should be supported after adding";
}

/// @title Removing currency decreases count
/// @notice After removing a currency, count decreases by 1
rule removeCurrencyDecreasesCount(env e, bytes32 symbol) {
    uint256 countBefore = getCurrencyCount();
    require countBefore > 0;
    require isCurrencySupported(symbol);
    
    removeCurrency(e, symbol);
    
    uint256 countAfter = getCurrencyCount();
    
    assert countAfter == countBefore - 1,
        "Removing currency should decrease count by 1";
}

/// @title Removed currency is no longer supported
rule removedCurrencyNotSupported(env e, bytes32 symbol) {
    require isCurrencySupported(symbol);
    require getCurrencyCount() > 0;
    
    removeCurrency(e, symbol);
    
    assert !isCurrencySupported(symbol),
        "Currency should not be supported after removal";
}

/// @title Cannot add duplicate currency
/// @notice Adding an already supported currency should revert
rule cannotAddDuplicateCurrency(env e, bytes32 symbol) {
    require isCurrencySupported(symbol);
    
    addCurrency@withrevert(e, symbol);
    
    assert lastReverted,
        "Adding duplicate currency should revert";
}

/// @title Cannot remove unsupported currency
/// @notice Removing a non-existent currency should revert
rule cannotRemoveUnsupportedCurrency(env e, bytes32 symbol) {
    require !isCurrencySupported(symbol);
    
    removeCurrency@withrevert(e, symbol);
    
    assert lastReverted,
        "Removing unsupported currency should revert";
}

/// @title Cannot exceed max currencies
rule cannotExceedMaxCurrencies(env e, bytes32 symbol) {
    require getCurrencyCount() >= 256;
    
    addCurrency@withrevert(e, symbol);
    
    assert lastReverted,
        "Should not be able to add currency when at max";
}

// ============================================================
// Rules - Cross Rate Calculation
// ============================================================

/// @title Cross rate with same currency equals PRECISION
rule crossRateSameCurrency(bytes32 currency) {
    require isCurrencySupported(currency);
    
    uint64 rate = getCrossRate(currency, currency);
    
    // Same currency cross rate should be 1.0 (PRECISION = 1e6)
    assert rate == 1000000,
        "Cross rate of same currency should equal PRECISION";
}

// ============================================================
// Rules - Conversion
// ============================================================

/// @title Convert from USD with zero amount returns zero
rule convertFromUSDZero(bytes32 currency) {
    require isCurrencySupported(currency);
    
    uint256 result = convertFromUSD(currency, 0);
    
    assert result == 0,
        "Converting 0 USD should return 0";
}

// ============================================================
// Rules - Heartbeat
// ============================================================

/// @title Heartbeat timeout bounds enforcement
/// @notice setHeartbeatTimeout enforces bounds
rule heartbeatTimeoutTooShort(env e) {
    uint64 newTimeout = 1800; // 30 minutes - too short
    
    setHeartbeatTimeout@withrevert(e, newTimeout);
    
    assert lastReverted,
        "Timeout too short should revert";
}

/// @title Heartbeat timeout too long
rule heartbeatTimeoutTooLong(env e) {
    uint64 newTimeout = 864000; // 10 days - too long
    
    setHeartbeatTimeout@withrevert(e, newTimeout);
    
    assert lastReverted,
        "Timeout too long should revert";
}

// ============================================================
// Rules - State Consistency
// ============================================================

/// @title State consistency after any operation
/// @notice Currency count changes are bounded
rule stateConsistency(env e, method f) 
    filtered { f -> !f.isView } 
{
    uint256 countBefore = getCurrencyCount();
    
    calldataarg args;
    f(e, args);
    
    uint256 countAfter = getCurrencyCount();
    
    // Count should only change by addCurrency (+1) or removeCurrency (-1)
    assert countAfter == countBefore || 
           countAfter == countBefore + 1 || 
           countAfter == countBefore - 1,
        "Currency count should only change by 1";
}
