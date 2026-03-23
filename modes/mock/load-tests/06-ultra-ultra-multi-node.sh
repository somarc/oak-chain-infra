#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
mkdir -p "$LOG_DIR"

# Draft profile: fan ingress across all cluster nodes instead of single-node entry.
TEST_NAME_PREFIX="${TEST_NAME_PREFIX:-ultra-ultra-30min}"
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-1800}"
NODES_CSV="${NODES_CSV:-8090,8092,8094}"
NUM_CLIENTS_TOTAL="${NUM_CLIENTS_TOTAL:-36}"
MIN_WRITES_PER_CLIENT="${MIN_WRITES_PER_CLIENT:-2000}"
MAX_WRITES_PER_CLIENT="${MAX_WRITES_PER_CLIENT:-20000}"
BINARY_PERCENT="${BINARY_PERCENT:-40}"
VALIDATOR_BINARY_PERCENT="${VALIDATOR_BINARY_PERCENT:-10}"
SLEEP_MIN_MS="${SLEEP_MIN_MS:-5}"
SLEEP_MAX_MS="${SLEEP_MAX_MS:-50}"
REGISTER_CLIENTS="${REGISTER_CLIENTS:-true}"

IFS=',' read -r -a NODE_PORTS <<< "$NODES_CSV"
NODE_COUNT="${#NODE_PORTS[@]}"
if [ "$NODE_COUNT" -lt 1 ]; then
  echo "❌ NODES_CSV produced zero nodes"
  exit 1
fi

BASE_CLIENTS=$((NUM_CLIENTS_TOTAL / NODE_COUNT))
EXTRA_CLIENTS=$((NUM_CLIENTS_TOTAL % NODE_COUNT))

PIDS=()
CLIENT_OFFSET=0

cleanup() {
  for p in "${PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM HUP

echo "Ultra-Ultra Multi-Node Draft"
echo "- Nodes: $NODES_CSV"
echo "- Clients total: $NUM_CLIENTS_TOTAL"
echo "- Duration: ${TEST_DURATION_SECONDS}s"
echo "- Writes/client: ${MIN_WRITES_PER_CLIENT}-${MAX_WRITES_PER_CLIENT}"
echo "- Binary rate: ${BINARY_PERCENT}% (validator-hosted ${VALIDATOR_BINARY_PERCENT}%)"

for idx in "${!NODE_PORTS[@]}"; do
  port="${NODE_PORTS[$idx]}"
  clients="$BASE_CLIENTS"
  if [ "$idx" -lt "$EXTRA_CLIENTS" ]; then
    clients=$((clients + 1))
  fi
  test_name="${TEST_NAME_PREFIX}-node-${port}"
  validator_url="http://localhost:${port}"

  echo "• Launching ${test_name} -> ${validator_url} with ${clients} clients"
  (
    export TEST_NAME="$test_name"
    export VALIDATOR_URL="$validator_url"
    export CLIENT_ID_OFFSET="$CLIENT_OFFSET"
    export TEST_DURATION_SECONDS
    export NUM_CLIENTS="$clients"
    export MIN_WRITES_PER_CLIENT
    export MAX_WRITES_PER_CLIENT
    export BINARY_PERCENT
    export VALIDATOR_BINARY_PERCENT
    export SLEEP_MIN_MS
    export SLEEP_MAX_MS
    export REGISTER_CLIENTS
    source "$SCRIPT_DIR/run-load-test.sh"
  ) &
  PIDS+=("$!")
  CLIENT_OFFSET=$((CLIENT_OFFSET + clients))
done

rc=0
for p in "${PIDS[@]}"; do
  if ! wait "$p"; then
    rc=1
  fi
done

echo "✅ Multi-node run complete (rc=$rc)"
echo "Logs: $LOG_DIR/${TEST_NAME_PREFIX}-node-*.log"
exit "$rc"
