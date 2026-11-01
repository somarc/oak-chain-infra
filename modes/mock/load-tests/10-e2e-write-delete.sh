#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$MOCK_DIR/validators/lifecycle"
source "$SCRIPT_DIR/suite-lib.sh"

VALIDATOR_URL="${VALIDATOR_URL:-http://127.0.0.1:8090}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/05-ultra-30min.sh}"
WAIT_DRAIN_TIMEOUT_SECONDS="${WAIT_DRAIN_TIMEOUT_SECONDS:-5400}"
WAIT_DRAIN_POLL_SECONDS="${WAIT_DRAIN_POLL_SECONDS:-10}"
DELETE_MAX="${DELETE_MAX:-0}"
DELETE_SLEEP_MS="${DELETE_SLEEP_MS:-20}"
START_CLUSTER_ARGS="${START_CLUSTER_ARGS:---build --fresh}"
SKIP_CLUSTER_RESTART="${SKIP_CLUSTER_RESTART:-false}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required."
  exit 1
fi

# Class D (deletes and --fresh unless SKIP_CLUSTER_RESTART=true): refuse the protected
# live root unless OAK_ALLOW_LIVE_ROOT=1, and refuse when the cluster ports or the
# VALIDATOR_URL port belong to another root.
source "$LIFECYCLE_DIR/lib/root-guard.sh"
oak_guard_require_target_from_env "write/delete e2e (class D; start-cluster ${START_CLUSTER_ARGS}, SKIP_CLUSTER_RESTART=${SKIP_CLUSTER_RESTART})" \
  "$(oak_guard_url_port "$VALIDATOR_URL")" || exit 1

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="${LOG_DIR}/e2e-write-delete-${RUN_TS}.log"
CAPTURE_DIR="${LOG_DIR}/e2e-accepted-${RUN_TS}"

api_get() {
  local path="$1"
  curl -s "${VALIDATOR_URL}${path}"
}

queue_snapshot_line() {
  api_get "/v1/proposals/queue/stats" | jq -r '
    "pending=\(.pendingCount // 0) " +
    "batch=\(.batchQueueSize // 0) " +
    "verified=\(.verifiedCount // 0) " +
    "mempool=\(.mempoolPendingCount // 0) " +
    "persist=\(.persistencePendingChanges // 0) " +
    "bp_raw=\(.backpressurePendingRawCount // 0) " +
    "finalized=\(.totalFinalizedCount // 0) " +
    "processed=\(.processedCount // 0)"
  '
}

queue_is_empty() {
  api_get "/v1/proposals/queue/stats" | jq -e '
    (.pendingCount // 0) == 0 and
    (.batchQueueSize // 0) == 0 and
    (.verifiedCount // 0) == 0 and
    (.mempoolPendingCount // 0) == 0 and
    (.persistencePendingChanges // 0) == 0 and
    (.backpressurePendingRawCount // 0) == 0
  ' >/dev/null
}

wait_for_queue_empty() {
  local label="$1"
  local timeout="${2:-$WAIT_DRAIN_TIMEOUT_SECONDS}"
  local start
  start="$(date +%s)"
  log_line "$RUN_LOG" "Waiting for queue empty: ${label} (timeout=${timeout}s)"
  while true; do
    if queue_is_empty; then
      log_line "$RUN_LOG" "Queue empty (${label}): $(queue_snapshot_line)"
      return 0
    fi
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_line "$RUN_LOG" "TIMEOUT waiting for queue empty (${label}) after ${elapsed}s"
      log_line "$RUN_LOG" "Last snapshot: $(queue_snapshot_line)"
      return 1
    fi
    if [ $((elapsed % 60)) -eq 0 ]; then
      log_line "$RUN_LOG" "Still draining (${label}, t=${elapsed}s): $(queue_snapshot_line)"
    fi
    sleep "$WAIT_DRAIN_POLL_SECONDS"
  done
}

log_line "$RUN_LOG" "Starting e2e-write-delete run=${RUN_TS}"
log_line "$RUN_LOG" "Validator URL: ${VALIDATOR_URL}"
log_line "$RUN_LOG" "Load script: ${LOAD_SCRIPT}"
log_line "$RUN_LOG" "Capture dir: ${CAPTURE_DIR}"

if [ "$SKIP_CLUSTER_RESTART" != "true" ]; then
  log_line "$RUN_LOG" "Starting fresh cluster via start-cluster.sh ${START_CLUSTER_ARGS}"
  # shellcheck disable=SC2086
  "$LIFECYCLE_DIR/start-cluster.sh" $START_CLUSTER_ARGS
else
  log_line "$RUN_LOG" "Skipping cluster restart (SKIP_CLUSTER_RESTART=true)"
fi

wait_for_queue_empty "pre-load baseline" 120

log_line "$RUN_LOG" "Running load phase with accepted-write capture"
CAPTURE_WRITE_ACCEPTS=true \
CAPTURE_WRITE_ACCEPTS_DIR="$CAPTURE_DIR" \
bash "$LOAD_SCRIPT"

wait_for_queue_empty "post-load drain"

log_line "$RUN_LOG" "Running delete replay phase"
if [ "$DELETE_MAX" -gt 0 ]; then
  "$SCRIPT_DIR/09-delete-replay.sh" \
    --input "$CAPTURE_DIR" \
    --max-deletes "$DELETE_MAX" \
    --sleep-ms "$DELETE_SLEEP_MS" \
    --validator-url "$VALIDATOR_URL"
else
  "$SCRIPT_DIR/09-delete-replay.sh" \
    --input "$CAPTURE_DIR" \
    --sleep-ms "$DELETE_SLEEP_MS" \
    --validator-url "$VALIDATOR_URL"
fi

wait_for_queue_empty "post-delete drain"

log_line "$RUN_LOG" "Final queue snapshot: $(queue_snapshot_line)"
log_line "$RUN_LOG" "✅ e2e-write-delete complete"
echo "RUN_LOG=${RUN_LOG}"
