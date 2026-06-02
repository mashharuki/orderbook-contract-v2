#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOLC="$ROOT/certora/solc-0.8.24"

if command -v certoraRun >/dev/null 2>&1; then
    exec certoraRun certora/specs/Sera.conf --solc "$SOLC" "$@"
fi

if command -v pipx >/dev/null 2>&1; then
    exec pipx run --spec certora-cli certoraRun certora/specs/Sera.conf --solc "$SOLC" "$@"
fi

cat >&2 <<'EOF'
Could not find certoraRun or pipx.

Install one of:
  pipx install certora-cli
  python3 -m pip install certora-cli
EOF
exit 127
