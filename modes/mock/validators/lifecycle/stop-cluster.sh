#!/bin/bash
set -euo pipefail

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"

for node in 0 1 2; do
  pid_file="$PID_DIR/validator-${node}.pid"
  if [ ! -f "$pid_file" ]; then
    echo "• Validator-$node not running (no pid file)"
    continue
  fi

  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "• Stopping validator-$node (PID $pid)"
    kill "$pid" || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      echo "  - force kill $pid"
      kill -9 "$pid" || true
    fi
  else
    echo "• Validator-$node pid file stale"
  fi
  rm -f "$pid_file"
done

if [ -f "$OPS_PROXY_PID_FILE" ]; then
  ops_pid="$(cat "$OPS_PROXY_PID_FILE")"
  if kill -0 "$ops_pid" 2>/dev/null; then
    echo "• Stopping OPS proxy (PID $ops_pid)"
    kill "$ops_pid" || true
    sleep 1
    if kill -0 "$ops_pid" 2>/dev/null; then
      echo "  - force kill $ops_pid"
      kill -9 "$ops_pid" || true
    fi
  else
    echo "• OPS proxy pid file stale"
  fi
  rm -f "$OPS_PROXY_PID_FILE"
else
  echo "• OPS proxy not running (no pid file)"
fi

echo "✅ Stop sequence complete"
