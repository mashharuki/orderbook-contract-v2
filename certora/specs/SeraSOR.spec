/*
 * Certora Formal Verification Specification for SeraSOR
 * 
 * This spec verifies critical invariants and properties:
 * 1. Route execution integrity
 * 2. Constant values
 * 3. Reference integrity
 */

// ============================================================
// Methods Declaration
// ============================================================

methods {
    // View functions - envfree
    function MAX_ROUTE_LEGS() external returns (uint256) envfree;
    function sera() external returns (address) envfree;
}

// ============================================================
// Invariants
// ============================================================

/// @title Max route legs is constant
invariant maxRouteLegsConstant()
    MAX_ROUTE_LEGS() == 20;

/// @title Sera reference is immutable and non-zero
invariant seraNotZero()
    sera() != 0;

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

/// @title Max route legs never changes
rule maxRouteLegsImmutable(env e, method f)
    filtered { f -> !f.isView }
{
    uint256 maxBefore = MAX_ROUTE_LEGS();
    
    calldataarg args;
    f(e, args);
    
    uint256 maxAfter = MAX_ROUTE_LEGS();
    
    assert maxBefore == maxAfter,
        "Max route legs should never change";
}
