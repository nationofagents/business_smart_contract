#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Config ──────────────────────────────────────
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${PRIVATE_KEY:?Set PRIVATE_KEY env var}"
VERIFY="${VERIFY:-false}"
ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-}"

echo "=== Deploying BusinessContract ==="
echo "RPC: $RPC_URL"

FORGE_ARGS=(
    script/Deploy.s.sol:DeployScript
    --rpc-url "$RPC_URL"
    --private-key "$PRIVATE_KEY"
    --broadcast
    -vvvv
)

if [ "$VERIFY" = "true" ] && [ -n "$ETHERSCAN_API_KEY" ]; then
    FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
fi

forge "${FORGE_ARGS[@]}"

echo ""
echo "=== Deployment complete ==="
echo "Check broadcast/ directory for the deployed address."
