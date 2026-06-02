# Sera Certora Proofs

Run from the repository root:

```sh
certora/run-sera.sh --compilation_steps_only
```

That command compiles Solidity and typechecks `certora/specs/Sera.spec` locally without submitting a cloud verification job.

To submit the full Certora proof:

```sh
export CERTORAKEY=...
certora/run-sera.sh
```

To run one focused rule while iterating:

```sh
certora/run-sera.sh --rule calculateSettlementUpdatesFillAndKeepsBounds
```

The runner pins Solidity to `0.8.24` through `certora/solc-0.8.24`. If the wrapper cannot find a cached compiler, point it at one explicitly:

```sh
SERA_SOLC_0_8_24=/path/to/solc-0.8.24 certora/run-sera.sh --compilation_steps_only
```

Useful local Solidity check:

```sh
forge build certora/harness/SeraCertoraHarness.sol --skip test script
```

Note: a full `forge build` currently fails before reaching this harness because `test/formal/SeraOracleFormal.t.sol` imports missing `src/SeraOracle.sol`.
