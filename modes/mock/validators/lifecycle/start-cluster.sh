#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_SCRIPT="$SCRIPT_DIR/../debug/run-validator-node.sh"
PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
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

echo "✅ Start sequence submitted. Use status-cluster.sh to verify health."
