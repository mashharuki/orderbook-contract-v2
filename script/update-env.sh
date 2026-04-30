#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Copyright 2025 Working Ants Inc. (Panama)
#
# Populate .env with addresses from a completed Deploy.s.sol broadcast.
#
# Usage:
#   script/update-env.sh                # defaults to chain 1 (mainnet)
#   script/update-env.sh 11155111       # sepolia
#
# Idempotent: re-running after another deploy overwrites the addresses.
# Works with both empty placeholders (VAR=0x) and previously-filled values.

set -euo pipefail

CHAIN_ID="${1:-1}"
BROADCAST_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
ENV_FILE=".env"

command -v jq >/dev/null 2>&1 || { echo "error: jq not installed (brew install jq)" >&2; exit 1; }

[[ -f "$BROADCAST_FILE" ]] || { echo "error: $BROADCAST_FILE not found — run Deploy.s.sol with --broadcast first" >&2; exit 1; }
[[ -f "$ENV_FILE" ]]       || { echo "error: $ENV_FILE not found — copy .env.example to .env first" >&2; exit 1; }

# First CREATE tx per contract name = the canonical deployment.
pluck() {
    jq -r --arg name "$1" '[.transactions[] | select(.transactionType=="CREATE" and .contractName==$name)][0].contractAddress // empty' "$BROADCAST_FILE"
}

VAULT=$(pluck Vault)
SERA=$(pluck Sera)
SOR=$(pluck SeraSOR)
BATCHER=$(pluck SeraBatcher)
DEPLOYER=$(jq -r '.transactions[0].transaction.from // empty' "$BROADCAST_FILE")

for name in VAULT SERA SOR BATCHER DEPLOYER; do
    [[ -n "${!name}" ]] || { echo "error: could not extract $name from $BROADCAST_FILE" >&2; exit 1; }
done

# Portable in-place sed (BSD sed on macOS needs a suffix arg; GNU accepts it too).
rewrite() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$ENV_FILE"; then
        sed -i.bak -E "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" && rm "${ENV_FILE}.bak"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

rewrite DEPLOYER        "$DEPLOYER"
rewrite VAULT_ADDRESS   "$VAULT"
rewrite SERA_ADDRESS    "$SERA"
rewrite SOR_ADDRESS     "$SOR"
rewrite BATCHER_ADDRESS "$BATCHER"

echo "Updated $ENV_FILE from $BROADCAST_FILE:"
printf '  %-17s %s\n' DEPLOYER= "$DEPLOYER"
printf '  %-17s %s\n' VAULT_ADDRESS= "$VAULT"
printf '  %-17s %s\n' SERA_ADDRESS= "$SERA"
printf '  %-17s %s\n' SOR_ADDRESS= "$SOR"
printf '  %-17s %s\n' BATCHER_ADDRESS= "$BATCHER"
