#!/bin/bash
set -e

HOST="${HOST:-http://localhost}"
NODES="${NODES:-8090,8092,8094}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-10}"
DURATION_SECONDS="${DURATION_SECONDS:-900}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

QUEUE_CSV="${LOG_DIR}/queue-samples-${TIMESTAMP}.csv"
METRICS_CSV="${LOG_DIR}/metrics-${TIMESTAMP}.csv"
LOG_WATCH="${LOG_DIR}/validator-log-watch-${TIMESTAMP}.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
  log "Stopping monitors..."
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT

log "Bottleneck study runner"
log "Host: ${HOST}"
log "Nodes: ${NODES}"
log "Interval: ${INTERVAL_SECONDS}s"
log "Duration: ${DURATION_SECONDS}s"
log "Logs: ${LOG_DIR}"

PIDS=()

log "Starting queue sampler..."
python3 "$(dirname "$0")/queue-sampler.py" \
  --host "${HOST}" \
  --nodes "${NODES}" \
  --interval "${INTERVAL_SECONDS}" \
  --duration "${DURATION_SECONDS}" \
  --out "${QUEUE_CSV}" &
PIDS+=($!)

log "Starting metrics monitor..."
VALIDATOR_URL="${HOST}:${NODES%%,*}" \
INTERVAL_SECONDS="${INTERVAL_SECONDS}" \
DURATION_SECONDS="${DURATION_SECONDS}" \
CSV_LOG="${METRICS_CSV}" \
LOG_DIR="${LOG_DIR}" \
"$(dirname "$0")/monitor-metrics.sh" &
PIDS+=($!)

log "Starting validator log watcher..."
LOG_DIR="${LOG_DIR}" \
OUT_DIR="${LOG_DIR}" \
OUT_FILE="${LOG_WATCH}" \
"$(dirname "$0")/monitor-validator-logs.sh" &
PIDS+=($!)

log "Monitors running (PIDs: ${PIDS[*]})"
log "Queue samples: ${QUEUE_CSV}"
log "Metrics CSV: ${METRICS_CSV}"
log "Log watch: ${LOG_WATCH}"

sleep "${DURATION_SECONDS}"
log "Duration complete."
