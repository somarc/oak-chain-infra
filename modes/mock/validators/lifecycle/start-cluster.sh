#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_SCRIPT="$SCRIPT_DIR/../debug/run-validator-node.sh"
PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
OAK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
OPS_DASHBOARD_DIR="${OPS_DASHBOARD_DIR:-$OAK_ROOT/oak-chain-dashboard-eds}"
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"
OPS_PROXY_LOG_FILE="$LOG_DIR/start-ops-proxy.log"
OPS_PROXY_PORT="${OPS_PROXY_PORT:-8787}"
OPS_PROXY_MODE="${OPS_PROXY_MODE:-proxy}"
OPS_PROXY_UPSTREAM="${OPS_PROXY_UPSTREAM:-http://127.0.0.1:8090}"
NODES=(0 1 2)

mkdir -p "$PID_DIR" "$LOG_DIR"

if ! command -v ipfs >/dev/null 2>&1; then
  echo "⚠️  ipfs CLI not found; skipping daemon check"
else
  if ! pgrep -f "ipfs daemon" >/dev/null 2>&1; then
    echo "⚠️  IPFS daemon is not running. Start it with: ipfs daemon"
  else
    echo "✅ IPFS daemon detected"
  fi
fi

for node in "${NODES[@]}"; do
  pid_file="$PID_DIR/validator-${node}.pid"
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "• Validator-$node already running (PID $(cat "$pid_file"))"
    continue
  fi

  echo "• Starting validator-$node"
  nohup "$VALIDATOR_SCRIPT" "$node" > "$LOG_DIR/start-validator-${node}.log" 2>&1 &
  echo $! > "$pid_file"
  sleep 1

done

if [ -f "$OPS_PROXY_PID_FILE" ] && kill -0 "$(cat "$OPS_PROXY_PID_FILE")" 2>/dev/null; then
  echo "• OPS proxy already running (PID $(cat "$OPS_PROXY_PID_FILE"))"
else
  if [ ! -d "$OPS_DASHBOARD_DIR" ]; then
    echo "⚠️  OPS proxy skipped: dashboard repo not found at $OPS_DASHBOARD_DIR"
  elif [ ! -f "$OPS_DASHBOARD_DIR/package.json" ]; then
    echo "⚠️  OPS proxy skipped: package.json missing in $OPS_DASHBOARD_DIR"
  else
    echo "• Starting OPS proxy on :$OPS_PROXY_PORT (mode=$OPS_PROXY_MODE upstream=$OPS_PROXY_UPSTREAM)"
    (
      cd "$OPS_DASHBOARD_DIR"
      OPS_MOCK_MODE="$OPS_PROXY_MODE" \
      OPS_UPSTREAM_BASE="$OPS_PROXY_UPSTREAM" \
      OPS_MOCK_PORT="$OPS_PROXY_PORT" \
      nohup npm run mock:ops > "$OPS_PROXY_LOG_FILE" 2>&1 &
      echo $! > "$OPS_PROXY_PID_FILE"
    )
    sleep 1
  fi
fi

echo "✅ Start sequence submitted. Use status-cluster.sh to verify health."
