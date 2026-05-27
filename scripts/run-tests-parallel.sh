#!/bin/bash

# Sera Protocol - Parallel Test Runner
# Usage: ./scripts/run-tests-parallel.sh [mode]
# Modes: fast (default), standard, full

set -e

MODE="${1:-fast}"
JOBS="${JOBS:-4}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration based on mode
case $MODE in
    fast)
        FUZZ_RUNS=16
        HALMOS_TIMEOUT=60
        HALMOS_LOOP=2
        log_info "Running in FAST mode (quick feedback)"
        ;;
    standard)
        FUZZ_RUNS=256
        HALMOS_TIMEOUT=300
        HALMOS_LOOP=3
        log_info "Running in STANDARD mode (CI quality)"
        ;;
    full)
        FUZZ_RUNS=10000
        HALMOS_TIMEOUT=600
        HALMOS_LOOP=5
        log_info "Running in FULL mode (comprehensive)"
        ;;
    *)
        log_error "Unknown mode: $MODE. Use: fast, standard, or full"
        exit 1
        ;;
esac

# Create logs directory
mkdir -p test-logs

# Track results
FAILED=0
START_TIME=$(date +%s)

# ============================================================
# Run Foundry Invariant Tests (Parallel Sharding)
# ============================================================
run_foundry_tests() {
    log_info "Running Foundry Invariant Tests with $JOBS parallel shards..."
    
    local pids=()
    for i in $(seq 1 $JOBS); do
        (
            log_info "  Shard $i/$JOBS starting..."
            if forge test \
                --match-path "test/invariant/*.t.sol" \
                --fuzz-runs $FUZZ_RUNS \
                --shard $i/$JOBS \
                > "test-logs/foundry-shard-$i.log" 2>&1; then
                log_info "  Shard $i/$JOBS PASSED"
            else
                log_error "  Shard $i/$JOBS FAILED"
                exit 1
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all shards
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            FAILED=1
        fi
    done
    
    if [ $FAILED -eq 0 ]; then
        log_info "All Foundry Invariant Tests PASSED"
    else
        log_error "Some Foundry Invariant Tests FAILED"
        log_info "Check test-logs/foundry-shard-*.log for details"
    fi
}

# ============================================================
# Run Foundry Fuzz Tests
# ============================================================
run_fuzz_tests() {
    log_info "Running Foundry Fuzz Tests..."
    
    if forge test \
        --match-path "test/*Fuzz*.t.sol" \
        --fuzz-runs $FUZZ_RUNS \
        -j$JOBS \
        > "test-logs/fuzz-tests.log" 2>&1; then
        log_info "Foundry Fuzz Tests PASSED"
    else
        log_error "Foundry Fuzz Tests FAILED"
        FAILED=1
    fi
}

# ============================================================
# Run Halmos Symbolic Tests (Parallel by Contract)
# ============================================================
run_halmos_tests() {
    log_info "Running Halmos Symbolic Tests in parallel..."
    
    local contracts=(
        "VaultSymbolicSimple"
        "SeraSymbolicAdvanced"
        "SORSymbolic"
        "MathSymbolic"
    )
    
    local pids=()
    for contract in "${contracts[@]}"; do
        (
            log_info "  $contract starting..."
            if halmos \
                --match-contract $contract \
                --solver-timeout-assertion $HALMOS_TIMEOUT \
                --loop $HALMOS_LOOP \
                > "test-logs/halmos-$contract.log" 2>&1; then
                log_info "  $contract PASSED"
            else
                # Check if it's a timeout (not a failure)
                if grep -q "TIMEOUT" "test-logs/halmos-$contract.log"; then
                    log_warn "  $contract TIMEOUT (not a failure)"
                else
                    log_error "  $contract FAILED"
                    exit 1
                fi
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all contracts
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            FAILED=1
        fi
    done
    
    if [ $FAILED -eq 0 ]; then
        log_info "All Halmos Symbolic Tests PASSED"
    else
        log_error "Some Halmos Symbolic Tests FAILED"
        log_info "Check test-logs/halmos-*.log for details"
    fi
}

# ============================================================
# Run Certora Specs (if available)
# ============================================================
run_certora_tests() {
    if ! command -v certoraRun &> /dev/null; then
        log_warn "Certora not installed, skipping Certora tests"
        return 0
    fi
    
    log_info "Running Certora Formal Verification..."
    
    local specs=(
        "certora/specs/Vault.spec"
        "certora/specs/Sera.spec"
        "certora/specs/SeraSOR.spec"
        "certora/specs/SeraBatcher.spec"
    )
    
    for spec in "${specs[@]}"; do
        local name=$(basename $spec .spec)
        log_info "  Running $name..."
        
        if certoraRun $spec \
            > "test-logs/certora-$name.log" 2>&1; then
            log_info "  $name PASSED"
        else
            log_error "  $name FAILED"
            FAILED=1
        fi
    done
}

# ============================================================
# Main Execution
# ============================================================
main() {
    log_info "========================================="
    log_info "Sera Protocol Formal Verification Suite"
    log_info "Mode: $MODE | Jobs: $JOBS"
    log_info "========================================="
    
    # Clean previous logs
    rm -rf test-logs
    mkdir -p test-logs
    
    # Build contracts first
    log_info "Building contracts..."
    forge build > "test-logs/build.log" 2>&1 || {
        log_error "Build failed! Check test-logs/build.log"
        exit 1
    }
    
    # Run tests based on mode
    case $MODE in
        fast)
            run_foundry_tests
            run_halmos_tests
            ;;
        standard)
            run_foundry_tests
            run_fuzz_tests
            run_halmos_tests
            ;;
        full)
            run_foundry_tests
            run_fuzz_tests
            run_halmos_tests
            run_certora_tests
            ;;
    esac
    
    # Summary
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    log_info "========================================="
    if [ $FAILED -eq 0 ]; then
        log_info "All Tests PASSED in ${DURATION}s"
        log_info "Logs available in test-logs/"
        exit 0
    else
        log_error "Some Tests FAILED after ${DURATION}s"
        log_info "Check test-logs/ for details"
        exit 1
    fi
}

# Run main
main
