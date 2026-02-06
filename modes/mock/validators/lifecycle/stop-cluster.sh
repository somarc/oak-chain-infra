#!/bin/bash
set -euo pipefail

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"

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

echo "✅ Stop sequence complete"
