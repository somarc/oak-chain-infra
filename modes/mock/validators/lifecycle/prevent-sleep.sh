#!/bin/bash
set -euo pipefail

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
PID_FILE="$PID_DIR/caffeinate.pid"

mkdir -p "$PID_DIR"

is_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}

read_pid_file() {
  local pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return 1
  fi
  tr -d '[:space:]' <"$pid_file"
}

list_validator_pids() {
  local pids=()
  local pid_file
  local pid

  shopt -s nullglob
  for pid_file in "$PID_DIR"/validator-*.pid; do
    pid="$(read_pid_file "$pid_file" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      pids+=("$pid")
    else
      rm -f "$pid_file"
    fi
  done
  shopt -u nullglob

  if [ "${#pids[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${pids[@]}"
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

    validator_pids="$(list_validator_pids | tr '\n' ' ' | xargs || true)"
    if [ -z "$validator_pids" ]; then
      echo "sleep-prevention:DOWN reason=no-validators"
      exit 1
    fi

    nohup caffeinate -d -i -m >/dev/null 2>&1 &
    cp=$!
    sleep 1
    if is_pid_alive "$cp"; then
      echo "$cp" >"$PID_FILE"
      echo "sleep-prevention:UP pid=$cp validators=\"${validator_pids}\""
    else
      echo "sleep-prevention:DOWN reason=caffeinate-failed"
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
        validator_pids="$(list_validator_pids | tr '\n' ' ' | xargs || true)"
        if [ -n "$validator_pids" ]; then
          echo "sleep-prevention:DOWN reason=not-running validators=\"${validator_pids}\""
        else
          echo "sleep-prevention:DOWN"
        fi
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
