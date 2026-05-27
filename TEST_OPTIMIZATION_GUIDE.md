# Sera Protocol - Test Optimization Guide

This guide explains how to run formal verification tests efficiently while maintaining comprehensive coverage.

---

## Quick Reference

### Fast Local Testing (30 seconds)
```bash
# Quick smoke tests
forge test --match-path "test/invariant/*.t.sol" --fuzz-runs 16 -j4

# Quick Halmos tests
halmos --match-contract VaultSymbolicSimple --solver-timeout-assertion 60
```

### Full Test Suite (30-60 minutes)
```bash
# Run all invariant tests with high fuzz runs
forge test --match-path "test/invariant/*.t.sol" --fuzz-runs 10000 -j4

# Run all Halmos tests with extended timeout
halmos --solver-timeout-assertion 600 --solver-timeout-branching 600
```

---

## Test Performance Overview

| Test Suite | Test Count | Fast Mode | Full Mode | Parallel Speedup |
|------------|-----------|-----------|-----------|-----------------|
| Foundry Invariant | 109 tests | 5 min | 60 min | 5x with -j4 |
| Halmos Symbolic | 58 properties | 2 min | 45 min | 4x parallel |
| Foundry Fuzz | 30+ tests | 3 min | 120 min | 2x with shards |

---

## Optimization Strategies

### 1. Parallel Execution (Recommended)

#### Foundry Parallel Testing
```bash
# Use -j4 for 4 parallel jobs (adjust based on CPU cores)
forge test --match-path "test/invariant/*.t.sol" -j4 --fuzz-runs 256

# Shard tests across multiple machines/processes
forge test --match-path "test/invariant/*.t.sol" --shard 1/4 --fuzz-runs 256
forge test --match-path "test/invariant/*.t.sol" --shard 2/4 --fuzz-runs 256
forge test --match-path "test/invariant/*.t.sol" --shard 3/4 --fuzz-runs 256
forge test --match-path "test/invariant/*.t.sol" --shard 4/4 --fuzz-runs 256
```

#### Halmos Parallel Testing
```bash
# Run different contracts in parallel
halmos --match-contract VaultSymbolicSimple &
halmos --match-contract SeraSymbolicAdvanced &
halmos --match-contract SORSymbolic &
halmos --match-contract MathSymbolic &
wait
```

### 2. Fuzz Run Configuration

| Mode | Runs | Use Case | Time |
|------|------|---------|------|
| Smoke | 16 | CI quick check | 30s |
| Fast | 256 | Local development | 5min |
| Standard | 1000 | PR validation | 15min |
| Full | 10000 | Release testing | 60min |
| Extensive | 100000 | Security audit | 10hr |

```bash
# Example: Fast mode for development
forge test --fuzz-runs 256

# Example: Standard mode for CI
forge test --fuzz-runs 1000

# Example: Full mode for releases
forge test --fuzz-runs 10000
```

### 3. Halmos Solver Tuning

#### Fast Mode (for CI)
```bash
halmos \
  --solver-timeout-assertion 60 \
  --solver-timeout-branching 60 \
  --loop 2
```

#### Standard Mode
```bash
halmos \
  --solver-timeout-assertion 300 \
  --solver-timeout-branching 300 \
  --loop 3
```

#### Full Mode (thorough verification)
```bash
halmos \
  --solver-timeout-assertion 0 \
  --solver-timeout-branching 0 \
  --loop 5
```

### 4. Selective Testing

#### Test by Category
```bash
# Math operations only
halmos --match-contract MathSymbolic

# Vault only
forge test --match-contract VaultInvariant
halmos --match-contract VaultSymbolicSimple

# Sera order matching
forge test --match-contract SeraInvariant
halmos --match-contract SeraSymbolicAdvanced

# Security tests
forge test --match-path "test/invariant/*Security*.t.sol"
```

#### Test by Function
```bash
# Run specific Halmos check
halmos --function check_feeCalculation

# Run specific Foundry test
forge test --match-test testFuzz_depositAmountValidation
```

---

## CI/CD Integration

### GitHub Actions (see `.github/workflows/formal-verification.yml`)

```yaml
# Matrix strategy for parallel execution
strategy:
  matrix:
    shard: [1, 2, 3, 4, 5]

steps:
  - run: |
      forge test \
        --match-path "test/invariant/*.t.sol" \
        --fuzz-runs 256 \
        --shard ${{ matrix.shard }}/5
```

### Local Parallel Script

```bash
#!/bin/bash
# run-tests-parallel.sh

# Number of parallel jobs
JOBS=4

# Run Foundry tests in parallel
echo "Running Foundry invariant tests..."
for i in $(seq 1 $JOBS); do
  forge test \
    --match-path "test/invariant/*.t.sol" \
    --fuzz-runs 256 \
    --shard $i/$JOBS \
    > "foundry-shard-$i.log" 2>&1 &
done
wait

# Run Halmos tests in parallel
echo "Running Halmos symbolic tests..."
for contract in VaultSymbolicSimple SeraSymbolicAdvanced SORSymbolic MathSymbolic; do
  halmos \
    --match-contract $contract \
    --solver-timeout-assertion 300 \
    > "halmos-$contract.log" 2>&1 &
done
wait

echo "All tests complete!"
```

---

## Performance Benchmarks

### Hardware Recommendations

| Test Type | CPU | RAM | Time (Full) |
|-----------|-----|-----|-------------|
| Foundry Fuzz | 8 cores | 16GB | 30 min |
| Halmos Symbolic | 16 cores | 32GB | 45 min |
| Combined | 16 cores | 32GB | 60 min |

### Optimizing for Your Machine

```bash
# Check CPU cores
nproc

# Set optimal parallel jobs (use 75% of cores)
JOBS=$(( $(nproc) * 3 / 4 ))

# Run with optimal parallelism
forge test -j$JOBS
```

---

## Troubleshooting Slow Tests

### Halmos Timeout Issues

```bash
# If check_feeCalculation times out:
# 1. Reduce bounds in test
# 2. Increase timeout
halmos --function check_feeCalculation --solver-timeout-assertion 600

# 3. Or disable timeout (infinite)
halmos --function check_feeCalculation --solver-timeout-assertion 0
```

### Foundry Memory Issues

```bash
# Reduce parallel jobs
forge test -j2

# Or run sequentially
forge test -j1

# Clear cache if needed
forge clean
```

### Slow Compilation

```bash
# Use incremental compilation
export FOUNDRY_OPTIMIZER=false

# Or compile once then test
forge build
forge test --no-rebuild
```

---

## Best Practices

### 1. Test Organization
- **Fast tests**: `test/smoke/` - Run on every commit
- **Invariant tests**: `test/invariant/` - Run on PRs
- **Symbolic tests**: `test/halmos/` - Run before releases
- **Fuzz tests**: `test/fuzz/` - Run nightly

### 2. CI Pipeline
```
Commit → Smoke Tests (30s) → PR Created → Full Tests (60min) → Merge
                ↓                         ↓
         Quick Feedback           Comprehensive Check
```

### 3. Local Development Workflow
```bash
# 1. Quick check during development (30 seconds)
forge test --fuzz-runs 16

# 2. Before commit (5 minutes)
forge test --fuzz-runs 256
halmos --solver-timeout-assertion 60

# 3. Before PR (60 minutes)
forge test --fuzz-runs 10000
halmos --solver-timeout-assertion 600
```

---

## Test Coverage Matrix

| Component | Invariant Tests | Symbolic Tests | Fuzz Tests | Total |
|-----------|-----------------|----------------|------------|-------|
| Vault | 27 | 11 | 18 | 56 |
| Sera | 34 | 47 | 25 | 106 |
| SeraSOR | 6 | 25 | - | 31 |
| SeraBatcher | 8 | - | - | 8 |
| Security | 34 | - | - | 34 |
| **Total** | **109** | **83** | **43** | **235+** |

---

## Environment Variables

### Foundry
```bash
# Parallel jobs
export FOUNDRY_TEST_JOBS=4

# Fuzz runs default
export FOUNDRY_FUZZ_RUNS=256

# Verbosity
export FOUNDRY_VERBOSITY=2
```

### Halmos
```bash
# Solver timeout
export HALMOS_SOLVER_TIMEOUT=300

# Loop unrolling
export HALMOS_LOOP=3

# Parallel verification
export HALMOS_PARALLEL=4
```

---

## Summary

**For fastest feedback during development:**
```bash
forge test --fuzz-runs 16 -j4
```

**For comprehensive pre-release testing:**
```bash
./scripts/run-full-verification.sh
```

**Recommended CI setup:**
- Smoke tests: 16 runs, 5 minute timeout
- PR tests: 256 runs, 30 minute timeout  
- Release tests: 10000 runs, 2 hour timeout
