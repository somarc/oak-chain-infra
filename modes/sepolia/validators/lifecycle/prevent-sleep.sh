#!/bin/bash
set -euo pipefail

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
PID_FILE="$PID_DIR/caffeinate.pid"

mkdir -p "$PID_DIR"

is_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}

case "${1:-start}" in
  start)
    if ! command -v caffeinate >/dev/null 2>&1; then
      echo "sleep-prevention:UNAVAILABLE caffeinate-not-found"
      exit 0
    fi

    if [ -f "$PID_FILE" ]; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if is_pid_alive "$pid"; then
        echo "sleep-prevention:UP pid=$pid"
        exit 0
      fi
      rm -f "$PID_FILE"
    fi

    validator_pids="$(pgrep -f "oak-segment-consensus" | tr '\n' ' ' | xargs || true)"
    if [ -z "$validator_pids" ]; then
      echo "sleep-prevention:DOWN reason=no-validators"
      exit 1
    fi

    first_pid="$(echo "$validator_pids" | awk '{print $1}')"
    if [ -z "$first_pid" ]; then
      echo "sleep-prevention:DOWN reason=no-first-pid"
      exit 1
    fi

    caffeinate -d -i -m -s -u -w "$first_pid" >/dev/null 2>&1 &
    cp=$!
    sleep 1
    if is_pid_alive "$cp"; then
      echo "$cp" >"$PID_FILE"
      echo "sleep-prevention:UP pid=$cp validator=$first_pid"
    else
      echo "sleep-prevention:DOWN reason=caffeinate-failed validator=$first_pid"
      exit 1
    fi
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if is_pid_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if is_pid_alive "$pid"; then
          kill -9 "$pid" 2>/dev/null || true
        fi
      fi
      rm -f "$PID_FILE"
      echo "sleep-prevention:DOWN"
    else
      echo "sleep-prevention:DOWN"
    fi
    ;;
  status)
    if [ -f "$PID_FILE" ]; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if is_pid_alive "$pid"; then
        echo "sleep-prevention:UP pid=$pid"
      else
        rm -f "$PID_FILE"
        echo "sleep-prevention:DOWN stale-pid"
      fi
    else
      echo "sleep-prevention:DOWN"
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop|status]"
    exit 1
    ;;
esac
