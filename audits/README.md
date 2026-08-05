# Security Audits

This directory contains third-party security audit reports for the Sera orderbook contracts.

## Reports

- [`2026-04-30-certik-sera-final.pdf`](./2026-04-30-certik-sera-final.pdf) — CertiK, final report.

## TLDR

- **Auditor:** CertiK
- **Date:** 2026-04-30
- **Report:** [`2026-04-30-certik-sera-final.pdf`](./2026-04-30-certik-sera-final.pdf) (final)
- **Scope:** all first-party contracts under `src/` — `Sera`, `SeraSOR`, `SeraBatcher`, `SeraAdmin`, `SeraBase`, `SeraLib`, `Vault`, and `IVault`. Test fixtures, deploy scripts, mocks, and vendored / third-party libraries (`vendor/compound-timelock/`, `lib/openzeppelin-contracts/`, `lib/solady/`, `lib/forge-std/`) are out of scope.
- **Status:** All in-scope findings have been addressed in the post-audit code. Proof-of-concept tests validating findings live under [`../test/SeraSOR_DeepAudit.t.sol`](../test/SeraSOR_DeepAudit.t.sol) and [`../test/SeraSOR_SigBypassPoC.t.sol`](../test/SeraSOR_SigBypassPoC.t.sol); see [`../test/summary.md`](../test/summary.md) for an audit-test cross-reference.
- For severity breakdown, individual findings, and remediation discussion, **see the PDF**.

## License / redistribution

The PDF report(s) in this directory are authored by their respective auditors and distributed with their permission as part of our audit engagement(s). Copyright in those reports remains with the authoring auditor — they are **not** covered by the repository's [LICENSE](../LICENSE) (PolyForm Noncommercial 1.0.0). Redistribution of the report content is governed by the terms of the underlying audit engagement, not by this project's license.

This `README.md` itself (the index file you are reading) is first-party content authored by Working Ants Inc. and is licensed under the PolyForm Noncommercial License 1.0.0 — see [../LICENSE](../LICENSE).

> Required Notice: Copyright 2025 Working Ants Inc. (Panama)
