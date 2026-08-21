#!/usr/bin/env sh
set -eu

RPC_URL="${E2E_RPC_URL:-http://127.0.0.1:8545}"
started_anvil=0

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  anvil --port 8545 >/tmp/sera-experience-anvil.log 2>&1 &
  anvil_pid=$!
  started_anvil=1
  trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT INT TERM
  until cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; do sleep 1; done
fi

# Anvil's documented default accounts. Override any of these to use different
# local actors; this script intentionally refuses to target a public RPC.
case "$RPC_URL" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "E2E_RPC_URL must be a local Anvil endpoint" >&2; exit 1;; esac
export DEMO_DEPLOYER_PRIVATE_KEY="${DEMO_DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
export DEMO_TAKER_PRIVATE_KEY="${DEMO_TAKER_PRIVATE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
export DEMO_MAKER_ONE_PRIVATE_KEY="${DEMO_MAKER_ONE_PRIVATE_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
export DEMO_MAKER_TWO_PRIVATE_KEY="${DEMO_MAKER_TWO_PRIVATE_KEY:-0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6}"
export DEMO_EXECUTOR_PRIVATE_KEY="${DEMO_EXECUTOR_PRIVATE_KEY:-0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a}"

forge script script/ExperienceLocal.s.sol:ExperienceLocal --rpc-url "$RPC_URL" --broadcast

# Finish the delayed-withdrawal path that the Solidity walkthrough starts.
# Mining is Anvil-only and happens after the request transaction, so it cannot
# accidentally advance time or blocks on an externally managed chain.
run_file="broadcast/ExperienceLocal.s.sol/31337/run-latest.json"
sera_address=$(jq -r '.transactions[] | select(.transactionType == "CREATE" and .contractName == "Sera") | .contractAddress' "$run_file" | head -1)
sgd_address=$(jq -r '.transactions[] | select(.transactionType == "CREATE" and .contractName == "MockStableCoin") | .contractAddress' "$run_file" | sed -n '3p')
# Mining all 7,200 blocks in one JSON-RPC request can exceed a provider/client
# timeout on slower machines. Mine 100 at a time instead: the outcome is the
# same block delay, while each Anvil response stays short and reliable.
mined_blocks=0
while [ "$mined_blocks" -lt 7200 ]; do
  cast rpc --rpc-url "$RPC_URL" anvil_mine 0x64 >/dev/null
  mined_blocks=$((mined_blocks + 100))
done
cast send --rpc-url "$RPC_URL" --private-key "$DEMO_TAKER_PRIVATE_KEY" "$sera_address" \
  'emergencyWithdraw(address,uint256)' "$sgd_address" 1000000000000000000 >/dev/null
echo "6. delayed withdrawal execution after 7,200 mined Anvil blocks: OK"

if [ "$started_anvil" -eq 1 ]; then
  echo "Anvil was stopped after the walkthrough. Its log was written to /tmp/sera-experience-anvil.log."
fi
