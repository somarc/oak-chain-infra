#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
POSTMORTEM_DIR="${POSTMORTEM_DIR:-$HOME/oak-chain/postmortem}"

OBSERVER_PID_FILE="${OBSERVER_PID_FILE:-$PID_DIR/load-bottleneck-observer.pid}"
OBSERVER_LOG_FILE="${OBSERVER_LOG_FILE:-$LOG_DIR/load-bottleneck-observer.log}"

OPS_BASE="${OPS_BASE:-http://127.0.0.1:8787}"
HOST_BASE="${HOST_BASE:-http://127.0.0.1}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
OBSERVER_INTERVAL_SECONDS="${OBSERVER_INTERVAL_SECONDS:-5}"
OBSERVER_QUEUE_THRESHOLD="${OBSERVER_QUEUE_THRESHOLD:-8000}"
OBSERVER_BACKPRESSURE_THRESHOLD="${OBSERVER_BACKPRESSURE_THRESHOLD:-8000}"
OBSERVER_VERIFIER_WAIT_MAX_THRESHOLD_MS="${OBSERVER_VERIFIER_WAIT_MAX_THRESHOLD_MS:-5000}"
OBSERVER_SUSTAIN_COUNT="${OBSERVER_SUSTAIN_COUNT:-3}"
OBSERVER_COOLDOWN_SECONDS="${OBSERVER_COOLDOWN_SECONDS:-600}"
OBSERVER_JSTACK_DURATION_SECONDS="${OBSERVER_JSTACK_DURATION_SECONDS:-180}"
OBSERVER_JSTACK_DELAY_SECONDS="${OBSERVER_JSTACK_DELAY_SECONDS:-10}"

if [ "$CLUSTER_SIZE" = "5" ]; then
  PORTS=(8090 8092 8094 8096 8098)
else
  PORTS=(8090 8092 8094)
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--start|--run|--stop|--status] [--interval N]

Commands:
  --start      Start bottleneck observer in background.
  --run        Run observer loop in foreground.
  --stop       Stop observer.
  --status     Print observer status.

Options:
  --interval N Poll interval in seconds (default: $OBSERVER_INTERVAL_SECONDS)
EOF
}

is_pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$OBSERVER_LOG_FILE" >/dev/null
}

capture_snapshot() {
  local reason="$1"
  local now_ts
  local cap_dir
  now_ts="$(date '+%Y%m%d-%H%M%S')"
  cap_dir="$POSTMORTEM_DIR/load-bottleneck-${now_ts}"
  mkdir -p "$cap_dir"

  {
    echo "timestamp=${now_ts}"
    echo "reason=${reason}"
    echo "ops_base=${OPS_BASE}"
    echo "host_base=${HOST_BASE}"
    echo "cluster_size=${CLUSTER_SIZE}"
    echo "ports=${PORTS[*]}"
  } > "$cap_dir/summary.env"

  curl -s "$OPS_BASE/ops/v1/overview" > "$cap_dir/ops-overview.json" 2>/dev/null || true
  curl -s "$OPS_BASE/ops/v1/signals" > "$cap_dir/ops-signals.json" 2>/dev/null || true
  curl -s "$OPS_BASE/ops/v1/queue" > "$cap_dir/ops-queue.json" 2>/dev/null || true
  curl -s "$OPS_BASE/ops/v1/proposals" > "$cap_dir/ops-proposals.json" 2>/dev/null || true

  for port in "${PORTS[@]}"; do
    curl -s "$HOST_BASE:$port/health" > "$cap_dir/validator-${port}-health.json" 2>/dev/null || true
    curl -s "$HOST_BASE:$port/v1/proposals/queue/stats" > "$cap_dir/validator-${port}-queue-stats.json" 2>/dev/null || true
    curl -s "$HOST_BASE:$port/v1/consensus/status" > "$cap_dir/validator-${port}-consensus-status.json" 2>/dev/null || true
  done

  local jstack_root="$cap_dir/jstack"
  mkdir -p "$jstack_root"
  for port in "${PORTS[@]}"; do
    local out_dir="$jstack_root/port-${port}"
    mkdir -p "$out_dir"
    "$SCRIPT_DIR/jstack-validator-series.sh" \
      --port "$port" \
      --duration "$OBSERVER_JSTACK_DURATION_SECONDS" \
      --delay "$OBSERVER_JSTACK_DELAY_SECONDS" \
      --out "$out_dir" > "$jstack_root/port-${port}.run.log" 2>&1 &
  done
  wait

  log "CAPTURE complete reason=${reason} path=${cap_dir}"
}

observer_loop() {
  local consecutive_over=0
  local last_capture_epoch=0

  log "observer started interval=${OBSERVER_INTERVAL_SECONDS}s cluster_size=${CLUSTER_SIZE} queue_threshold=${OBSERVER_QUEUE_THRESHOLD} backpressure_threshold=${OBSERVER_BACKPRESSURE_THRESHOLD}"
  while true; do
    local now_epoch
    local overview
    local signals
    local leader_node
    local leader_port
    local queue_pending
    local backpressure_pending
    local verifier_wait_max
    now_epoch="$(date +%s)"

    overview="$(curl -s "$OPS_BASE/ops/v1/overview" || true)"
    signals="$(curl -s "$OPS_BASE/ops/v1/signals" || true)"
    if [ -z "$overview" ] || [ -z "$signals" ]; then
      sleep "$OBSERVER_INTERVAL_SECONDS"
      continue
    fi

    leader_node="$(printf '%s' "$overview" | jq -r '.data.leader.nodeId // 0' 2>/dev/null || echo 0)"
    leader_port=$((8090 + (leader_node * 2)))
    queue_pending="$(printf '%s' "$overview" | jq -r '.data.queue.queuePending // .data.queue.pending // 0' 2>/dev/null || echo 0)"
    backpressure_pending="$(printf '%s' "$overview" | jq -r '.data.queue.backpressurePending // 0' 2>/dev/null || echo 0)"
    verifier_wait_max="$(printf '%s' "$overview" | jq -r '.data.queue.verifier.queueWaitMaxMs // 0' 2>/dev/null || echo 0)"
    if [ "$verifier_wait_max" = "0" ]; then
      verifier_wait_max="$(printf '%s' "$signals" | jq -r '((.data.signals // []) | map(select(.id=="verifier.queue_wait_max_ms") | .value) | .[0]) // 0' 2>/dev/null || echo 0)"
    fi

    if [ "$queue_pending" -ge "$OBSERVER_QUEUE_THRESHOLD" ] || [ "$backpressure_pending" -ge "$OBSERVER_BACKPRESSURE_THRESHOLD" ] || [ "$verifier_wait_max" -ge "$OBSERVER_VERIFIER_WAIT_MAX_THRESHOLD_MS" ]; then
      consecutive_over=$((consecutive_over + 1))
    else
      consecutive_over=0
    fi

    if [ "$consecutive_over" -ge "$OBSERVER_SUSTAIN_COUNT" ]; then
      if [ $((now_epoch - last_capture_epoch)) -ge "$OBSERVER_COOLDOWN_SECONDS" ]; then
        local reason="queue=${queue_pending},backpressure=${backpressure_pending},verifier_wait_max_ms=${verifier_wait_max},leader_port=${leader_port}"
        log "CAPTURE trigger ${reason}"
        capture_snapshot "$reason"
        last_capture_epoch="$now_epoch"
      fi
      consecutive_over=0
    fi

    sleep "$OBSERVER_INTERVAL_SECONDS"
  done
}

start_bg() {
  mkdir -p "$PID_DIR" "$LOG_DIR" "$POSTMORTEM_DIR"
  if [ -f "$OBSERVER_PID_FILE" ]; then
    local pid
    pid="$(cat "$OBSERVER_PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      echo "load-observer:UP pid=$pid log=$OBSERVER_LOG_FILE"
      return 0
    fi
    rm -f "$OBSERVER_PID_FILE"
  fi
  nohup "$0" --run --interval "$OBSERVER_INTERVAL_SECONDS" >> "$OBSERVER_LOG_FILE" 2>&1 &
  echo $! > "$OBSERVER_PID_FILE"
  sleep 1
  echo "load-observer:UP pid=$(cat "$OBSERVER_PID_FILE") log=$OBSERVER_LOG_FILE"
}

stop_bg() {
  if [ ! -f "$OBSERVER_PID_FILE" ]; then
    echo "load-observer:DOWN"
    return 0
  fi
  local pid
  pid="$(cat "$OBSERVER_PID_FILE" 2>/dev/null || true)"
  if is_pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    is_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$OBSERVER_PID_FILE"
  echo "load-observer:DOWN"
}

status_bg() {
  if [ -f "$OBSERVER_PID_FILE" ]; then
    local pid
    pid="$(cat "$OBSERVER_PID_FILE" 2>/dev/null || true)"
    if is_pid_alive "$pid"; then
      echo "load-observer:UP pid=$pid log=$OBSERVER_LOG_FILE"
      return 0
    fi
    echo "load-observer:DOWN stale-pid"
    return 1
  fi
  echo "load-observer:DOWN"
  return 1
}

CMD=""
while (($# > 0)); do
  case "$1" in
    --start|--run|--stop|--status) CMD="$1" ;;
    --interval)
      shift
      OBSERVER_INTERVAL_SECONDS="${1:-$OBSERVER_INTERVAL_SECONDS}"
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
    observer_loop
    ;;
  --stop) stop_bg ;;
  --status) status_bg ;;
  *) usage; exit 1 ;;
esac
