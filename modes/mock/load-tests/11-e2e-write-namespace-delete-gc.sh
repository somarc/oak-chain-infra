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
GC_APPROVAL_TIMEOUT_SECONDS="${GC_APPROVAL_TIMEOUT_SECONDS:-300}"
GC_APPROVAL_POLL_SECONDS="${GC_APPROVAL_POLL_SECONDS:-5}"
GC_VOTER_IDS="${GC_VOTER_IDS:-auto}"
GC_AUTO_VOTE="${GC_AUTO_VOTE:-true}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required."
  exit 1
fi

# Class D (namespace delete, GC, and --fresh when no cluster is running): refuse the protected
# live root unless OAK_ALLOW_LIVE_ROOT=1, and refuse when the cluster ports or the
# VALIDATOR_URL port belong to another root.
source "$LIFECYCLE_DIR/lib/root-guard.sh"
oak_guard_require_target_from_env "write/namespace-delete/GC e2e (class D; start-cluster ${START_CLUSTER_ARGS}, SKIP_CLUSTER_RESTART=${SKIP_CLUSTER_RESTART})" \
  "$(oak_guard_url_port "$VALIDATOR_URL")" || exit 1

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="${LOG_DIR}/e2e-write-namespace-delete-gc-${RUN_TS}.log"
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

resolve_gc_voter_ids() {
  if [ "$GC_VOTER_IDS" != "auto" ]; then
    echo "$GC_VOTER_IDS"
    return
  fi
  local state_json ids
  state_json="$(api_get "/v1/aeron/cluster-state" || true)"
  ids="$(printf '%s' "$state_json" | jq -r '
    [
      (.members // [] | map(.memberId // .nodeId)[]?),
      (.memberId // empty),
      (.nodeId // empty)
    ]
    | map(select(. != null))
    | unique
    | sort
    | map(tostring)
    | join(",")
  ' 2>/dev/null || true)"
  if [ -z "$ids" ]; then
    ids="0"
  fi
  log_line "$RUN_LOG" "Resolved GC voter IDs: ${ids}" >/dev/null
  echo "$ids"
}

get_gc_proposal_state() {
  local proposal_id="$1"
  api_get "/v1/compaction/proposals" | jq -r --arg id "$proposal_id" '
    (.proposals // []) | map(select(.proposalId == $id)) | .[0].state // "MISSING"
  ' 2>/dev/null || echo "MISSING"
}

gc_recently_executed() {
  local status_json pending last_run
  status_json="$(api_get "/v1/gc/status" || true)"
  pending="$(printf '%s' "$status_json" | jq -r '.pendingProposals // -1' 2>/dev/null || echo "-1")"
  last_run="$(printf '%s' "$status_json" | jq -r '.lastGcRun // empty' 2>/dev/null || true)"
  [ "$pending" = "0" ] && [ -n "$last_run" ]
}

cast_gc_votes() {
  local proposal_id="$1"
  local voters_csv
  voters_csv="$(resolve_gc_voter_ids)"
  IFS=',' read -r -a voters <<< "$voters_csv"
  for validator_id in "${voters[@]}"; do
    local trimmed
    trimmed="$(printf '%s' "$validator_id" | tr -d '[:space:]')"
    [ -n "$trimmed" ] || continue
    local vote_resp
    vote_resp="$(curl -s -X POST "${VALIDATOR_URL}/v1/gc/vote" \
      -H "Content-Type: application/json" \
      -d "{\"proposalId\":\"${proposal_id}\",\"validatorId\":${trimmed},\"approve\":true,\"reason\":\"e2e-auto-vote\"}")"
    log_line "$RUN_LOG" "GC vote response (validator=${trimmed}): $(printf '%s' "$vote_resp" | jq -c '.' 2>/dev/null || printf '%s' "$vote_resp")"
    sleep 0.2
  done
}

wait_for_gc_approved() {
  local proposal_id="$1"
  local timeout="${2:-$GC_APPROVAL_TIMEOUT_SECONDS}"
  local start
  start="$(date +%s)"
  log_line "$RUN_LOG" "Waiting for GC proposal approval: id=${proposal_id} timeout=${timeout}s"
  while true; do
    local state
    state="$(get_gc_proposal_state "$proposal_id")"
    if [ "$state" = "APPROVED" ] || [ "$state" = "EXECUTING" ] || [ "$state" = "COMPLETED" ]; then
      log_line "$RUN_LOG" "GC proposal state ready: id=${proposal_id} state=${state}"
      return 0
    fi
    if [ "$state" = "MISSING" ] && gc_recently_executed; then
      log_line "$RUN_LOG" "GC proposal not in pending list (likely auto-executed): id=${proposal_id} state=${state}"
      return 0
    fi
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_line "$RUN_LOG" "TIMEOUT waiting for GC approval: id=${proposal_id} state=${state} elapsed=${elapsed}s"
      return 1
    fi
    if [ $((elapsed % 30)) -eq 0 ]; then
      log_line "$RUN_LOG" "Still waiting for GC approval: id=${proposal_id} state=${state} elapsed=${elapsed}s"
    fi
    sleep "$GC_APPROVAL_POLL_SECONDS"
  done
}

pick_gc_wallet() {
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
  wallet="$(pick_gc_wallet)"
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

run_gc_phase() {
  local gc_wallet
  gc_wallet="$(pick_gc_wallet)"
  log_line "$RUN_LOG" "GC phase: proposing with wallet ${gc_wallet}"

  local propose_resp
  propose_resp="$(curl -s -X POST "${VALIDATOR_URL}/v1/propose-gc" \
    -H "Content-Type: application/json" \
    -d "{\"walletAddress\":\"${gc_wallet}\"}")"

  local proposal_id
  proposal_id="$(printf '%s' "$propose_resp" | jq -r '.proposalId // empty' 2>/dev/null || true)"
  log_line "$RUN_LOG" "GC propose response: $(printf '%s' "$propose_resp" | jq -c '.' 2>/dev/null || printf '%s' "$propose_resp")"

  if [ -n "$proposal_id" ] && [ "$GC_AUTO_VOTE" = "true" ]; then
    local status_resp consensus_required
    status_resp="$(api_get "/v1/gc/status" || true)"
    consensus_required="$(printf '%s' "$status_resp" | jq -r '.gcConsensusRequired // false' 2>/dev/null || echo "false")"
    if [ "$consensus_required" = "true" ]; then
      cast_gc_votes "$proposal_id"
      wait_for_gc_approved "$proposal_id" "$GC_APPROVAL_TIMEOUT_SECONDS" || true
    fi
  fi

  if [ -n "$proposal_id" ]; then
    local execute_resp
    execute_resp="$(curl -s -X POST "${VALIDATOR_URL}/v1/gc/execute" \
      -H "Content-Type: application/json" \
      -d "{\"proposalId\":\"${proposal_id}\"}")"
    log_line "$RUN_LOG" "GC execute response: $(printf '%s' "$execute_resp" | jq -c '.' 2>/dev/null || printf '%s' "$execute_resp")"
  fi

  local gc_status
  gc_status="$(api_get "/v1/gc/status" || true)"
  if [ -n "$gc_status" ]; then
    log_line "$RUN_LOG" "GC status snapshot: $(printf '%s' "$gc_status" | jq -c '.' 2>/dev/null || printf '%s' "$gc_status")"
  fi
}

log_line "$RUN_LOG" "Starting e2e-write-namespace-delete-gc run=${RUN_TS}"
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

run_gc_phase

wait_for_queue_empty "post-gc"

log_line "$RUN_LOG" "Final queue snapshot: $(queue_snapshot_line)"
log_line "$RUN_LOG" "✅ e2e-write-namespace-delete-gc complete"
echo "RUN_LOG=${RUN_LOG}"
