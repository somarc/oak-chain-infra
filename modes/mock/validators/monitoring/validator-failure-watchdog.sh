#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$BASE_DIR/lifecycle"

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
POSTMORTEM_DIR="${POSTMORTEM_DIR:-$HOME/oak-chain/postmortem}"
WATCHDOG_PID_FILE="${WATCHDOG_PID_FILE:-$PID_DIR/validator-watchdog.pid}"
WATCHDOG_LOG_FILE="${WATCHDOG_LOG_FILE:-$LOG_DIR/validator-watchdog.log}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"
HOST="${HOST:-http://127.0.0.1}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"

if [ "$CLUSTER_SIZE" = "5" ]; then
  NODE_IDS=(0 1 2 3 4)
  PORTS=(8090 8092 8094 8096 8098)
else
  NODE_IDS=(0 1 2)
  PORTS=(8090 8092 8094)
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--start|--run|--stop|--status] [--interval N]

Commands:
  --start        Start watchdog in background.
  --run          Run watchdog loop in foreground.
  --stop         Stop background watchdog.
  --status       Print watchdog status.

Options:
  --interval N   Poll interval in seconds (default: $WATCHDOG_INTERVAL_SECONDS)
EOF
}

is_pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$WATCHDOG_LOG_FILE" >/dev/null
}

capture_node_postmortem() {
  local node_id="$1"
  local port="$2"
  local ts dir pid
  ts="$(date '+%Y%m%d-%H%M%S')"
  dir="$POSTMORTEM_DIR/validator-${node_id}-${ts}"
  mkdir -p "$dir"

  pid=""
  if [ -f "$PID_DIR/validator-${node_id}.pid" ]; then
    pid="$(cat "$PID_DIR/validator-${node_id}.pid" 2>/dev/null || true)"
  fi

  {
    echo "node_id=$node_id"
    echo "port=$port"
    echo "timestamp=$ts"
    echo "pid_file=$PID_DIR/validator-${node_id}.pid"
    echo "pid=$pid"
    echo "pid_alive=$(is_pid_alive "$pid" && echo true || echo false)"
  } > "$dir/summary.env"

  {
    echo "=== date ==="
    date
    echo "=== uname ==="
    uname -a
    echo "=== status-cluster ==="
    "$LIFECYCLE_DIR/status-cluster.sh" || true
    echo "=== ps oak-segment-consensus ==="
    pgrep -fl "oak-segment-consensus" || true
  } > "$dir/system.txt" 2>&1

  {
    echo "=== /health ==="
    curl -sS "$HOST:$port/health" || true
    echo
    echo "=== /v1/aeron/cluster-state ==="
    curl -sS "$HOST:$port/v1/aeron/cluster-state" || true
    echo
    echo "=== /v1/consensus/status ==="
    curl -sS "$HOST:$port/v1/consensus/status" || true
    echo
    echo "=== /v1/proposals/queue/stats ==="
    curl -sS "$HOST:$port/v1/proposals/queue/stats" || true
  } > "$dir/api-snapshot.txt" 2>&1

  if command -v lsof >/dev/null 2>&1; then
    lsof -n -i :"$port" > "$dir/lsof-port-${port}.txt" 2>&1 || true
    if [ -n "$pid" ]; then
      lsof -p "$pid" > "$dir/lsof-pid-${pid}.txt" 2>&1 || true
    fi
  fi

  if [ -n "$pid" ] && is_pid_alive "$pid"; then
    ps -p "$pid" -o pid,ppid,user,etime,%cpu,%mem,state,command > "$dir/ps.txt" 2>&1 || true
    if command -v jcmd >/dev/null 2>&1; then
      jcmd "$pid" VM.command_line > "$dir/jcmd-command-line.txt" 2>&1 || true
      jcmd "$pid" VM.flags > "$dir/jcmd-vm-flags.txt" 2>&1 || true
      jcmd "$pid" Thread.print -l > "$dir/jcmd-thread-print.txt" 2>&1 || true
    elif command -v jstack >/dev/null 2>&1; then
      jstack -l "$pid" > "$dir/jstack.txt" 2>&1 || true
    fi
  fi

  tail -n 120 "$LOG_DIR/validator-${node_id}.log" > "$dir/validator-${node_id}.tail.log" 2>&1 || true
  tail -n 120 "$LOG_DIR/start-validator-${node_id}.log" > "$dir/start-validator-${node_id}.tail.log" 2>&1 || true

  {
    echo "=== fatal|error|exception summary ==="
    rg -n "FATAL|ERROR|Exception|OutOfMemory|DataStoreException|FileNotFoundException|backpressure|cluster connect timeout" \
      "$dir/validator-${node_id}.tail.log" "$dir/start-validator-${node_id}.tail.log" || true
  } > "$dir/error-highlights.txt" 2>&1

  log "ALERT validator-$node_id offline captured postmortem=$dir"
}

watchdog_loop() {
  prev_up_get() {
    local node="$1"
    eval "echo \${PREV_UP_${node}:-0}"
  }

  prev_up_set() {
    local node="$1"
    local val="$2"
    eval "PREV_UP_${node}=\"$val\""
  }

  local i node port code

  for i in "${!NODE_IDS[@]}"; do
    node="${NODE_IDS[$i]}"
    port="${PORTS[$i]}"
    code="$(curl -s -o /tmp/oak-watchdog-health-${port}.json -w "%{http_code}" "$HOST:$port/health" || echo 000)"
    if [ "$code" = "200" ]; then
      prev_up_set "$node" "1"
    else
      prev_up_set "$node" "0"
    fi
  done

  log "watchdog started interval=${WATCHDOG_INTERVAL_SECONDS}s cluster_size=$CLUSTER_SIZE"
  while true; do
    for i in "${!NODE_IDS[@]}"; do
      node="${NODE_IDS[$i]}"
      port="${PORTS[$i]}"
      code="$(curl -s -o /tmp/oak-watchdog-health-${port}.json -w "%{http_code}" "$HOST:$port/health" || echo 000)"
      if [ "$code" = "200" ]; then
        prev_up_set "$node" "1"
      else
        if [ "$(prev_up_get "$node")" = "1" ]; then
          capture_node_postmortem "$node" "$port"
        fi
        prev_up_set "$node" "0"
      fi
    done
    sleep "$WATCHDOG_INTERVAL_SECONDS"
  done
}

start_bg() {
  mkdir -p "$PID_DIR" "$LOG_DIR" "$POSTMORTEM_DIR"
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    local pid
    pid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      echo "validator-watchdog:UP pid=$pid log=$WATCHDOG_LOG_FILE"
      return 0
    fi
    rm -f "$WATCHDOG_PID_FILE"
  fi
  nohup "$0" --run --interval "$WATCHDOG_INTERVAL_SECONDS" >> "$WATCHDOG_LOG_FILE" 2>&1 &
  echo $! > "$WATCHDOG_PID_FILE"
  sleep 1
  echo "validator-watchdog:UP pid=$(cat "$WATCHDOG_PID_FILE") log=$WATCHDOG_LOG_FILE"
}

stop_bg() {
  if [ ! -f "$WATCHDOG_PID_FILE" ]; then
    echo "validator-watchdog:DOWN"
    return 0
  fi
  local pid
  pid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
  if is_pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    is_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$WATCHDOG_PID_FILE"
  echo "validator-watchdog:DOWN"
}

status_bg() {
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    local pid
    pid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      echo "validator-watchdog:UP pid=$pid log=$WATCHDOG_LOG_FILE"
      return 0
    fi
    echo "validator-watchdog:DOWN stale-pid"
    return 1
  fi
  echo "validator-watchdog:DOWN"
  return 1
}

CMD=""
while (($# > 0)); do
  case "$1" in
    --start|--run|--stop|--status) CMD="$1" ;;
    --interval)
      shift
      WATCHDOG_INTERVAL_SECONDS="${1:-$WATCHDOG_INTERVAL_SECONDS}"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

case "${CMD:---status}" in
  --start) start_bg ;;
  --run)
    mkdir -p "$PID_DIR" "$LOG_DIR" "$POSTMORTEM_DIR"
    watchdog_loop
    ;;
  --stop) stop_bg ;;
  --status) status_bg ;;
  *) usage; exit 1 ;;
esac
