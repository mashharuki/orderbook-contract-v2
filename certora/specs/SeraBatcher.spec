/*
 * Certora Formal Verification Specification for SeraBatcher
 * 
 * This spec verifies critical invariants and properties:
 * 1. Batch size limits
 * 2. Reference integrity
 * 3. Constant values
 */

// ============================================================
// Methods Declaration
// ============================================================

methods {
    // View functions - envfree
    function MAX_BATCH_SIZE() external returns (uint256) envfree;
    function MAX_INTENT_SIZE() external returns (uint256) envfree;
    function sera() external returns (address) envfree;
    function sor() external returns (address) envfree;
}

// ============================================================
// Invariants
// ============================================================

/// @title Max batch size is constant
invariant maxBatchSizeConstant()
    MAX_BATCH_SIZE() == 20;

/// @title Max intent size is constant
invariant maxIntentSizeConstant()
    MAX_INTENT_SIZE() == 10;

/// @title Sera reference is non-zero
invariant seraNotZero()
    sera() != 0;

/// @title SOR reference is non-zero
invariant sorNotZero()
    sor() != 0;

// ============================================================
// Rules - State Consistency
// ============================================================

/// @title Sera reference never changes
rule seraReferenceImmutable(env e, method f) 
    filtered { f -> !f.isView }
{
    address seraBefore = sera();
    
    calldataarg args;
    f(e, args);
    
    address seraAfter = sera();
    
    assert seraBefore == seraAfter,
        "Sera reference should never change";
}

/// @title SOR reference never changes
rule sorReferenceImmutable(env e, method f) 
    filtered { f -> !f.isView }
{
    address sorBefore = sor();
    
    calldataarg args;
    f(e, args);
    
    address sorAfter = sor();
    
    assert sorBefore == sorAfter,
        "SOR reference should never change";
}

/// @title Max batch size never changes
rule maxBatchSizeImmutable(env e, method f)
    filtered { f -> !f.isView }
{
    uint256 maxBefore = MAX_BATCH_SIZE();
    
    calldataarg args;
    f(e, args);
    
    uint256 maxAfter = MAX_BATCH_SIZE();
    
    assert maxBefore == maxAfter,
        "Max batch size should never change";
}

/// @title Max intent size never changes
rule maxIntentSizeImmutable(env e, method f)
    filtered { f -> !f.isView }
{
    uint256 maxBefore = MAX_INTENT_SIZE();
    
    calldataarg args;
    f(e, args);
    
    uint256 maxAfter = MAX_INTENT_SIZE();
    
    assert maxBefore == maxAfter,
        "Max intent size should never change";
}
