#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$MOCK_DIR/validators/lifecycle"
source "$SCRIPT_DIR/suite-lib.sh"

VALIDATOR_URL="${VALIDATOR_URL:-http://127.0.0.1:8090}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/11-namespace-delete-5min.sh}"
WAIT_DRAIN_TIMEOUT_SECONDS="${WAIT_DRAIN_TIMEOUT_SECONDS:-1800}"
WAIT_DRAIN_POLL_SECONDS="${WAIT_DRAIN_POLL_SECONDS:-5}"
START_CLUSTER_ARGS="${START_CLUSTER_ARGS:---fresh}"
SKIP_CLUSTER_RESTART="${SKIP_CLUSTER_RESTART:-auto}"
NAMESPACE_CLIENT="${NAMESPACE_CLIENT:-1}"
NAMESPACE_DELETE_PATH="${NAMESPACE_DELETE_PATH:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required."
  exit 1
fi

# Class D (namespace delete and --fresh when no cluster is running): refuse the protected
# live root unless OAK_ALLOW_LIVE_ROOT=1, and refuse when the cluster ports or the
# VALIDATOR_URL port belong to another root.
source "$LIFECYCLE_DIR/lib/root-guard.sh"
oak_guard_require_target_from_env "write/namespace-delete e2e (class D; start-cluster ${START_CLUSTER_ARGS}, SKIP_CLUSTER_RESTART=${SKIP_CLUSTER_RESTART})" \
  "$(oak_guard_url_port "$VALIDATOR_URL")" || exit 1

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="${LOG_DIR}/e2e-write-namespace-delete-${RUN_TS}.log"
CAPTURE_DIR="${LOG_DIR}/e2e-namespace-accepted-${RUN_TS}"

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

cluster_is_running() {
  curl -s --max-time 2 "${VALIDATOR_URL}/v1/proposals/queue/stats" \
    | jq -e 'type == "object" and ((.pendingCount // null) != null or (.batchQueueSize // null) != null)' \
    >/dev/null 2>&1
}

resolve_namespace_delete_target() {
  if [ -n "$NAMESPACE_DELETE_PATH" ]; then
    echo "$NAMESPACE_DELETE_PATH"
    return
  fi
  local capture_file="$CAPTURE_DIR/client-${NAMESPACE_CLIENT}.ndjson"
  if [ ! -f "$capture_file" ]; then
    echo ""
    return
  fi
  local first_path
  first_path="$(jq -r '.storagePath // empty' "$capture_file" | head -n 1)"
  if [ -z "$first_path" ]; then
    echo ""
    return
  fi
  dirname "$first_path"
}

pick_capture_wallet() {
  local wallet
  wallet="$(cat "$CAPTURE_DIR"/client-*.ndjson 2>/dev/null | jq -r '.wallet // empty' | head -n 1 || true)"
  if [ -z "$wallet" ]; then
    wallet="${WALLETS[0]}"
  fi
  echo "$wallet"
}

run_namespace_delete_phase() {
  local target_path
  target_path="$(resolve_namespace_delete_target)"
  if [ -z "$target_path" ]; then
    log_line "$RUN_LOG" "ERROR: Unable to resolve namespace delete target path"
    return 1
  fi

  local wallet
  wallet="$(pick_capture_wallet)"
  log_line "$RUN_LOG" "Namespace delete target: ${target_path}"
  log_line "$RUN_LOG" "Namespace delete wallet: ${wallet}"

  local body_file http_code delete_resp
  body_file="$(mktemp "${TMPDIR:-/tmp}/oak-namespace-delete.XXXXXX")"
  # Signed delete by the wallet's test key (oak-chain tx); a follower's 307 is followed with POST kept.
  http_code="$(submit_delete_proposal "$VALIDATOR_URL" "$wallet" "$target_path" "$body_file")"
  delete_resp="$(cat "$body_file" 2>/dev/null || true)"
  rm -f "$body_file"

  log_line "$RUN_LOG" "Namespace delete response (HTTP ${http_code}): $(printf '%s' "$delete_resp" | jq -c '.' 2>/dev/null || printf '%s' "$delete_resp")"
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    log_line "$RUN_LOG" "ERROR: namespace delete was not accepted (HTTP ${http_code})"
    return 1
  fi
}

log_line "$RUN_LOG" "Starting e2e-write-namespace-delete run=${RUN_TS}"
log_line "$RUN_LOG" "Validator URL: ${VALIDATOR_URL}"
log_line "$RUN_LOG" "Load script: ${LOAD_SCRIPT}"
log_line "$RUN_LOG" "Capture dir: ${CAPTURE_DIR}"

if [ "$SKIP_CLUSTER_RESTART" = "true" ]; then
  log_line "$RUN_LOG" "Skipping cluster restart (SKIP_CLUSTER_RESTART=true)"
elif [ "$SKIP_CLUSTER_RESTART" = "auto" ]; then
  if cluster_is_running; then
    log_line "$RUN_LOG" "Detected running validator at ${VALIDATOR_URL}; skipping cluster restart (SKIP_CLUSTER_RESTART=auto)"
  else
    log_line "$RUN_LOG" "No running validator detected at ${VALIDATOR_URL}; starting cluster via start-cluster.sh ${START_CLUSTER_ARGS}"
    # shellcheck disable=SC2086
    "$LIFECYCLE_DIR/start-cluster.sh" $START_CLUSTER_ARGS
  fi
else
  log_line "$RUN_LOG" "Starting cluster via start-cluster.sh ${START_CLUSTER_ARGS} (SKIP_CLUSTER_RESTART=${SKIP_CLUSTER_RESTART})"
  # shellcheck disable=SC2086
  "$LIFECYCLE_DIR/start-cluster.sh" $START_CLUSTER_ARGS
fi

wait_for_queue_empty "pre-load baseline" 120

log_line "$RUN_LOG" "Running namespace load phase with accepted-write capture"
CAPTURE_WRITE_ACCEPTS=true \
CAPTURE_WRITE_ACCEPTS_DIR="$CAPTURE_DIR" \
bash "$LOAD_SCRIPT"

wait_for_queue_empty "post-load drain"

log_line "$RUN_LOG" "Running namespace single-delete phase"
run_namespace_delete_phase

wait_for_queue_empty "post-namespace-delete drain"

log_line "$RUN_LOG" "Final queue snapshot: $(queue_snapshot_line)"
log_line "$RUN_LOG" "✅ e2e-write-namespace-delete complete"
echo "RUN_LOG=${RUN_LOG}"
