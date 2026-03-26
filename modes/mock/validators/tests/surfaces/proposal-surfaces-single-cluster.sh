#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$TESTS_DIR/../lifecycle"
CONFIG_DIR="$TESTS_DIR/../config"
OAK_ROOT="$(cd "$TESTS_DIR/../../../../.." && pwd)"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$CONFIG_DIR/single-cluster-3.env}"

START_CLUSTER="${START_CLUSTER:-true}"
START_CLUSTER_ARGS="${START_CLUSTER_ARGS:---fresh}"
WRITE_COUNT_PER_ORG="${WRITE_COUNT_PER_ORG:-72}"
WRITE_WAIT_SECONDS="${WRITE_WAIT_SECONDS:-90}"
READ_TIMEOUT_SECONDS="${READ_TIMEOUT_SECONDS:-90}"
READ_POLL_INTERVAL_SECONDS="${READ_POLL_INTERVAL_SECONDS:-2}"
QUEUE_EMPTY_TIMEOUT_SECONDS="${QUEUE_EMPTY_TIMEOUT_SECONDS:-300}"
QUEUE_EMPTY_POLL_SECONDS="${QUEUE_EMPTY_POLL_SECONDS:-5}"
HTTP_IDLE_SETTLE_SECONDS="${HTTP_IDLE_SETTLE_SECONDS:-5}"
RATE_LIMIT_RETRY_MAX="${RATE_LIMIT_RETRY_MAX:-5}"
RATE_LIMIT_RETRY_DELAY_SECONDS="${RATE_LIMIT_RETRY_DELAY_SECONDS:-2}"
NO_QUORUM_RETRY_MAX="${NO_QUORUM_RETRY_MAX:-15}"
NO_QUORUM_RETRY_DELAY_SECONDS="${NO_QUORUM_RETRY_DELAY_SECONDS:-2}"
RUN_STABILITY_SUITE="${RUN_STABILITY_SUITE:-true}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/oak-proposal-surfaces-single-cluster-artifacts}"
RUN_LOG="${ARTIFACT_ROOT}/run.log"
ORG_NAMESPACE_SUFFIX="${ORG_NAMESPACE_SUFFIX:-}"

export AUTO_START_IPFS="${AUTO_START_IPFS:-true}"
export IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"
export IPFS_READY_TIMEOUT_SECONDS="${IPFS_READY_TIMEOUT_SECONDS:-30}"

PRIMARY_WALLET="${PRIMARY_WALLET:-}"
SECONDARY_WALLET="${SECONDARY_WALLET:-}"
SMOKE_WALLET="${SMOKE_WALLET:-}"
FAILOVER_FOLLOWER_WALLET="${FAILOVER_FOLLOWER_WALLET:-}"
FAILOVER_LEADER_WALLET="${FAILOVER_LEADER_WALLET:-}"
CATCHUP_WALLET="${CATCHUP_WALLET:-}"
QUORUM_ENVELOPE_WALLET="${QUORUM_ENVELOPE_WALLET:-}"
DEFAULT_PRIMARY_WALLET="0x1100000000000000000000000000000000000000"
DEFAULT_SECONDARY_WALLET="0x2200000000000000000000000000000000000000"
DEFAULT_SMOKE_WALLET="0x3300000000000000000000000000000000000000"
DEFAULT_FAILOVER_FOLLOWER_WALLET="0x1111111111111111111111111111111111111111"
DEFAULT_FAILOVER_LEADER_WALLET="0x2222222222222222222222222222222222222222"
DEFAULT_CATCHUP_WALLET="0x4444444444444444444444444444444444444444"
DEFAULT_QUORUM_ENVELOPE_WALLET="0x5555555555555555555555555555555555555555"

ORG_BASES=(AtlasNorth AtlasSouth AtlasArchive)
ORGS=("${ORG_BASES[@]}")
if [ -n "$ORG_NAMESPACE_SUFFIX" ]; then
  ORGS=()
  for org in "${ORG_BASES[@]}"; do
    ORGS+=("${org}-${ORG_NAMESPACE_SUFFIX}")
  done
fi

usage() {
  cat <<'EOF'
Usage: ./proposal-surfaces-single-cluster.sh [--cluster-config PATH] [--skip-start] [--writes-per-org N] [--artifacts-dir PATH] [--skip-stability]

Bounded, non-load single-cluster proposal coverage:
  - fresh single-cluster bring-up (optional)
  - a few hundred writes per wallet using organization-scoped subtrees
  - individual delete, subtree delete, and full wallet namespace delete
  - Aeron graceful restart, hard crash, follower catch-up, and quorum-envelope probes

Environment:
  CLUSTER_CONFIG=/path/to/config.env
  START_CLUSTER=true|false
  START_CLUSTER_ARGS="--fresh"
  WRITE_COUNT_PER_ORG=72
  ARTIFACT_ROOT=/path/to/output
  RUN_STABILITY_SUITE=true|false
  AUTO_START_IPFS=true|false
EOF
}

mkdir -p "$ARTIFACT_ROOT"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$RUN_LOG"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

while (($# > 0)); do
  case "$1" in
    --cluster-config)
      shift
      CLUSTER_CONFIG="${1:-}"
      ;;
    --skip-start)
      START_CLUSTER=false
      ;;
    --writes-per-org)
      shift
      WRITE_COUNT_PER_ORG="${1:-}"
      ;;
    --artifacts-dir)
      shift
      ARTIFACT_ROOT="${1:-}"
      RUN_LOG="${ARTIFACT_ROOT}/run.log"
      mkdir -p "$ARTIFACT_ROOT"
      ;;
    --skip-stability)
      RUN_STABILITY_SUITE=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

require_cmd curl
require_cmd jq
require_cmd python3

if ! [[ "$WRITE_COUNT_PER_ORG" =~ ^[0-9]+$ ]] || [ "$WRITE_COUNT_PER_ORG" -le 0 ]; then
  fail "WRITE_COUNT_PER_ORG must be a positive integer"
fi

if ! [[ "$HTTP_IDLE_SETTLE_SECONDS" =~ ^[0-9]+$ ]]; then
  fail "HTTP_IDLE_SETTLE_SECONDS must be a non-negative integer"
fi

if ! [[ "$RATE_LIMIT_RETRY_MAX" =~ ^[0-9]+$ ]] || ! [[ "$NO_QUORUM_RETRY_MAX" =~ ^[0-9]+$ ]]; then
  fail "RATE_LIMIT_RETRY_MAX and NO_QUORUM_RETRY_MAX must be non-negative integers"
fi

consensus_jar_is_stale() {
  local consensus_jar="$OAK_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
  local -a watch_roots=(
    "$OAK_ROOT/jackrabbit-oak/oak-segment-consensus/src/main/java"
    "$OAK_ROOT/jackrabbit-oak/oak-segment-agentic/src/main/java"
  )

  if [ ! -f "$consensus_jar" ]; then
    return 0
  fi

  local root
  for root in "${watch_roots[@]}"; do
    if [ -d "$root" ] && find "$root" -type f -newer "$consensus_jar" -print -quit | grep -q .; then
      return 0
    fi
  done
  return 1
}

ensure_start_arg() {
  local arg="$1"
  case " $START_CLUSTER_ARGS " in
    *" $arg "*) ;;
    *)
      START_CLUSTER_ARGS="${START_CLUSTER_ARGS:+$START_CLUSTER_ARGS }$arg"
      ;;
  esac
}

load_cluster_env() {
  set -a
  for cfg in "${BASE_CONFIGS[@]}" "$CLUSTER_CONFIG"; do
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
    else
      fail "Missing config file: $cfg"
    fi
  done
  set +a
}

normalize_wallet() {
  local wallet="$1"
  wallet="${wallet#0x}"
  printf '%s\n' "$(printf '%s' "$wallet" | tr '[:upper:]' '[:lower:]')"
}

wallet_root_path() {
  local wallet
  wallet="$(normalize_wallet "$1")"
  printf '/oak-chain/%s/%s/%s/0x%s\n' "${wallet:0:2}" "${wallet:2:2}" "${wallet:4:2}" "$wallet"
}

wallet_org_content_path() {
  local wallet="$1"
  local organization="$2"
  printf '%s/%s/content\n' "$(wallet_root_path "$wallet")" "$organization"
}

if [ "$START_CLUSTER" = "true" ] && consensus_jar_is_stale; then
  ensure_start_arg "--build"
fi
ensure_start_arg "--no-watchdog"
ensure_start_arg "--no-load-observer"

load_cluster_env
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

PRIMARY_WALLET="${PRIMARY_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_PRIMARY_WALLET" 0)}"
SECONDARY_WALLET="${SECONDARY_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_SECONDARY_WALLET" 1)}"
SMOKE_WALLET="${SMOKE_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_SMOKE_WALLET" 2)}"
FAILOVER_FOLLOWER_WALLET="${FAILOVER_FOLLOWER_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_FAILOVER_FOLLOWER_WALLET" 3)}"
FAILOVER_LEADER_WALLET="${FAILOVER_LEADER_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_FAILOVER_LEADER_WALLET" 4)}"
CATCHUP_WALLET="${CATCHUP_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_CATCHUP_WALLET" 5)}"
QUORUM_ENVELOPE_WALLET="${QUORUM_ENVELOPE_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_QUORUM_ENVELOPE_WALLET" 6)}"

is_no_quorum_response() {
  local status="$1"
  local body="$2"
  [ "$status" = "503" ] &&
    [[ "$body" == *'"code":"service_unavailable"'* ]] &&
    [[ "$body" == *"no_quorum"* ]]
}

submit_write_request() {
  local base_url="$1"
  local wallet="$2"
  local organization="$3"
  local label="$4"
  local rate_limit_attempt=0
  local no_quorum_attempt=0

  while :; do
    local result
    local status
    local operation_id
    local storage_path
    local body
    result="$(submit_write "$base_url" "$wallet" "$label" "$organization")"
    status="$(echo "$result" | cut -d'|' -f1)"
    operation_id="$(echo "$result" | cut -d'|' -f2)"
    storage_path="$(echo "$result" | cut -d'|' -f3)"
    body="$(echo "$result" | cut -d'|' -f4-)"

    if [ "$status" = "429" ] && [ "$rate_limit_attempt" -lt "$RATE_LIMIT_RETRY_MAX" ]; then
      rate_limit_attempt=$((rate_limit_attempt + 1))
      log "RETRY ${label}: write received 429 (attempt ${rate_limit_attempt}/${RATE_LIMIT_RETRY_MAX}), sleeping ${RATE_LIMIT_RETRY_DELAY_SECONDS}s"
      sleep "$RATE_LIMIT_RETRY_DELAY_SECONDS"
      continue
    fi

    if is_no_quorum_response "$status" "$body" && [ "$no_quorum_attempt" -lt "$NO_QUORUM_RETRY_MAX" ]; then
      no_quorum_attempt=$((no_quorum_attempt + 1))
      log "RETRY ${label}: write received 503 no_quorum (attempt ${no_quorum_attempt}/${NO_QUORUM_RETRY_MAX}), sleeping ${NO_QUORUM_RETRY_DELAY_SECONDS}s"
      sleep "$NO_QUORUM_RETRY_DELAY_SECONDS"
      continue
    fi

    printf '%s|%s|%s|%s\n' "$status" "$operation_id" "$storage_path" "$body"
    return 0
  done
}

submit_delete_request() {
  local base_url="$1"
  local wallet="$2"
  local path="$3"
  local rate_limit_attempt=0
  local no_quorum_attempt=0

  while :; do
    local result
    local status
    local operation_id
    local body
    result="$(submit_delete "$base_url" "$wallet" "$path")"
    status="$(echo "$result" | cut -d'|' -f1)"
    operation_id="$(echo "$result" | cut -d'|' -f2)"
    body="$(echo "$result" | cut -d'|' -f3-)"

    if [ "$status" = "429" ] && [ "$rate_limit_attempt" -lt "$RATE_LIMIT_RETRY_MAX" ]; then
      rate_limit_attempt=$((rate_limit_attempt + 1))
      log "RETRY delete ${path}: received 429 (attempt ${rate_limit_attempt}/${RATE_LIMIT_RETRY_MAX}), sleeping ${RATE_LIMIT_RETRY_DELAY_SECONDS}s"
      sleep "$RATE_LIMIT_RETRY_DELAY_SECONDS"
      continue
    fi

    if is_no_quorum_response "$status" "$body" && [ "$no_quorum_attempt" -lt "$NO_QUORUM_RETRY_MAX" ]; then
      no_quorum_attempt=$((no_quorum_attempt + 1))
      log "RETRY delete ${path}: received 503 no_quorum (attempt ${no_quorum_attempt}/${NO_QUORUM_RETRY_MAX}), sleeping ${NO_QUORUM_RETRY_DELAY_SECONDS}s"
      sleep "$NO_QUORUM_RETRY_DELAY_SECONDS"
      continue
    fi

    printf '%s|%s|%s\n' "$status" "$operation_id" "$body"
    return 0
  done
}

assert_accepted() {
  local status="$1"
  local body="$2"
  local label="$3"
  case "$status" in
    200|202)
      log "ACCEPTED ${label}: http=${status}"
      ;;
    *)
      fail "${label} expected 200/202, got ${status}. body=${body}"
      ;;
  esac
}

wait_cluster_queue_empty() {
  local label="$1"
  local deadline
  deadline=$((SECONDS + QUEUE_EMPTY_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local all_empty=true
    local port
    for port in "${PORTS[@]}"; do
      local body
      body="$(curl -s "http://127.0.0.1:${port}/v1/proposals/queue/stats" || true)"
      if ! printf '%s' "$body" | jq -e '
        (.pendingCount // 0) == 0 and
        (.batchQueueSize // 0) == 0 and
        (.verifiedCount // 0) == 0 and
        (.mempoolPendingCount // 0) == 0 and
        (.persistencePendingChanges // 0) == 0 and
        (.backpressurePendingRawCount // 0) == 0
      ' >/dev/null 2>&1; then
        all_empty=false
        break
      fi
    done
    if [ "$all_empty" = true ]; then
      log "QUEUE EMPTY ${label}: ports=${PORTS[*]}"
      return 0
    fi
    sleep "$QUEUE_EMPTY_POLL_SECONDS"
  done

  fail "Queue did not drain for ${label}"
}

settle_http_idle() {
  local label="$1"
  if [ "$HTTP_IDLE_SETTLE_SECONDS" -le 0 ]; then
    return 0
  fi
  log "SETTLE ${label}: sleeping ${HTTP_IDLE_SETTLE_SECONDS}s for validator HTTP idle"
  sleep "$HTTP_IDLE_SETTLE_SECONDS"
}

explore_path() {
  local port="$1"
  local path="$2"
  local encoded
  local body_file
  local code
  encoded="$(encode_path "$path")"
  body_file="$(mktemp)"
  code="$(curl -s -o "$body_file" -w "%{http_code}" "http://127.0.0.1:${port}/api/explore?path=${encoded}" || echo "000")"
  printf '%s\n%s\n' "$code" "$(cat "$body_file")"
  rm -f "$body_file"
}

parent_lists_child_on_port() {
  local port="$1"
  local path="$2"
  local parent_path="${path%/*}"
  local child_name="${path##*/}"
  local result
  local code
  local body

  [ -n "$parent_path" ] || return 1
  [ "$parent_path" != "$path" ] || return 1

  result="$(explore_path "$port" "$parent_path")"
  code="$(printf '%s' "$result" | sed -n '1p')"
  body="$(printf '%s' "$result" | sed -n '2,$p')"

  [ "$code" = "200" ] || return 1
  printf '%s' "$body" | jq -e --arg child "$child_name" '(.children // []) | index($child) != null' >/dev/null 2>&1
}

wait_path_visible_on_port() {
  local port="$1"
  local path="$2"
  local label="$3"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local result
    local code
    local body
    result="$(explore_path "$port" "$path")"
    code="$(printf '%s' "$result" | sed -n '1p')"
    body="$(printf '%s' "$result" | sed -n '2,$p')"
    if [ "$code" = "200" ] && [ "$(json_field "$body" "path")" = "$path" ]; then
      log "VISIBLE ${label}: port=${port} path=${path}"
      return 0
    fi
    if parent_lists_child_on_port "$port" "$path"; then
      log "VISIBLE ${label}: port=${port} path=${path} via=parent-children"
      return 0
    fi
    sleep "$READ_POLL_INTERVAL_SECONDS"
  done
  fail "${label} did not become visible on port ${port}: ${path}"
}

wait_path_absent_on_port() {
  local port="$1"
  local path="$2"
  local label="$3"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local result
    local code
    result="$(explore_path "$port" "$path")"
    code="$(printf '%s' "$result" | sed -n '1p')"
    if [ "$code" = "404" ]; then
      log "ABSENT ${label}: port=${port} path=${path}"
      return 0
    fi
    sleep "$READ_POLL_INTERVAL_SECONDS"
  done
  fail "${label} still present on port ${port}: ${path}"
}

wait_child_count_on_port() {
  local port="$1"
  local path="$2"
  local expected_count="$3"
  local label="$4"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local result
    local code
    local body
    local count
    result="$(explore_path "$port" "$path")"
    code="$(printf '%s' "$result" | sed -n '1p')"
    body="$(printf '%s' "$result" | sed -n '2,$p')"
    if [ "$code" = "200" ]; then
      count="$(printf '%s' "$body" | jq -r '(.children // []) | length' 2>/dev/null || echo "-1")"
      if [ "$count" = "$expected_count" ]; then
        log "COUNT ${label}: port=${port} path=${path} count=${count}"
        return 0
      fi
    fi
    sleep "$READ_POLL_INTERVAL_SECONDS"
  done
  fail "${label} did not reach child-count ${expected_count} on port ${port}: ${path}"
}

wait_path_visible_all_ports() {
  local path="$1"
  local label="$2"
  local port
  for port in "${PORTS[@]}"; do
    wait_path_visible_on_port "$port" "$path" "$label"
  done
}

wait_path_absent_all_ports() {
  local path="$1"
  local label="$2"
  local port
  for port in "${PORTS[@]}"; do
    wait_path_absent_on_port "$port" "$path" "$label"
  done
}

wait_child_count_all_ports() {
  local path="$1"
  local expected_count="$2"
  local label="$3"
  local port
  for port in "${PORTS[@]}"; do
    wait_child_count_on_port "$port" "$path" "$expected_count" "$label"
  done
}

sample_paths_from_file() {
  local file="$1"
  local total
  total="$(wc -l < "$file" | tr -d ' ')"
  if [ "${total:-0}" -eq 0 ]; then
    return 0
  fi
  head -n 1 "$file"
  sed -n "$(((total + 1) / 2))p" "$file"
  tail -n 1 "$file"
}

leader_base_url() {
  local leader_port
  leader_port="$(find_leader_port || true)"
  [ -n "$leader_port" ] || fail "No leader detected"
  printf '%s:%s\n' "$HOST" "$leader_port"
}

write_batch() {
  local wallet="$1"
  local organization="$2"
  local count="$3"
  local output_file="$4"
  local submit_url
  local idx

  submit_url="$(leader_base_url)"
  log "LEADER write batch ${organization}: ${submit_url}"

  : > "$output_file"
  for ((idx=1; idx<=count; idx++)); do
    local label
    local result
    local status
    local storage_path
    local body
    label="[proposal-surfaces-single-cluster] ${organization}/${idx}"
    result="$(submit_write_request "$submit_url" "$wallet" "$organization" "$label")"
    status="$(echo "$result" | cut -d'|' -f1)"
    storage_path="$(echo "$result" | cut -d'|' -f3)"
    body="$(echo "$result" | cut -d'|' -f4-)"
    assert_accepted "$status" "$body" "write ${organization} #${idx}"
    [ -n "$storage_path" ] || fail "write ${organization} #${idx} missing storagePath"
    printf '%s\n' "$storage_path" >> "$output_file"
    if [ $((idx % 24)) -eq 0 ] || [ "$idx" -eq "$count" ]; then
      log "WRITE SUBMIT ${organization}: ${idx}/${count}"
    fi
  done
  log "WRITE SUBMIT COMPLETE ${organization}: ${count} proposals accepted"
}

delete_path_and_wait() {
  local wallet="$1"
  local path="$2"
  local label="$3"
  local submit_url
  local result
  local status
  local operation_id
  local body

  submit_url="$(leader_base_url)"
  log "LEADER delete ${label}: ${submit_url}"

  result="$(submit_delete_request "$submit_url" "$wallet" "$path")"
  status="$(echo "$result" | cut -d'|' -f1)"
  operation_id="$(echo "$result" | cut -d'|' -f2)"
  body="$(echo "$result" | cut -d'|' -f3-)"
  assert_accepted "$status" "$body" "delete ${label}"
  [ -n "$operation_id" ] || fail "delete ${label} missing operationId"
  wait_operation_committed "$submit_url" "$operation_id" || fail "delete ${label} did not commit"
  log "COMMITTED delete ${label}: op=${operation_id}"
}

run_logged_script() {
  local description="$1"
  shift
  log "RUN ${description}"
  "$@" 2>&1 | tee -a "$RUN_LOG"
}

PRIMARY_NORTH_FILE="${ARTIFACT_ROOT}/primary-atlas-north.paths"
PRIMARY_SOUTH_FILE="${ARTIFACT_ROOT}/primary-atlas-south.paths"
PRIMARY_ARCHIVE_FILE="${ARTIFACT_ROOT}/primary-atlas-archive.paths"
SECONDARY_NORTH_FILE="${ARTIFACT_ROOT}/secondary-atlas-north.paths"
SECONDARY_SOUTH_FILE="${ARTIFACT_ROOT}/secondary-atlas-south.paths"
SECONDARY_ARCHIVE_FILE="${ARTIFACT_ROOT}/secondary-atlas-archive.paths"

PRIMARY_NORTH_ROOT="$(wallet_org_content_path "$PRIMARY_WALLET" "${ORGS[0]}")"
PRIMARY_SOUTH_ROOT="$(wallet_org_content_path "$PRIMARY_WALLET" "${ORGS[1]}")"
PRIMARY_ARCHIVE_ROOT="$(wallet_org_content_path "$PRIMARY_WALLET" "${ORGS[2]}")"
SECONDARY_NORTH_ROOT="$(wallet_org_content_path "$SECONDARY_WALLET" "${ORGS[0]}")"
SECONDARY_SOUTH_ROOT="$(wallet_org_content_path "$SECONDARY_WALLET" "${ORGS[1]}")"
SECONDARY_ARCHIVE_ROOT="$(wallet_org_content_path "$SECONDARY_WALLET" "${ORGS[2]}")"
SECONDARY_WALLET_ROOT="$(wallet_root_path "$SECONDARY_WALLET")"

log "Artifacts: ${ARTIFACT_ROOT}"
log "Cluster: ${OAK_CLUSTER_NAME} size=${OAK_CLUSTER_SIZE} ports=${PORTS[*]} runtime=${CLUSTER_RUNTIME_ROOT}"
log "Write count per org: ${WRITE_COUNT_PER_ORG}"
log "Proposal wallets: primary=${PRIMARY_WALLET} secondary=${SECONDARY_WALLET}"
log "Organization namespace suffix: ${ORG_NAMESPACE_SUFFIX:-<none>}"
log "HTTP idle settle: ${HTTP_IDLE_SETTLE_SECONDS}s"
log "IPFS policy: AUTO_START_IPFS=${AUTO_START_IPFS} API=${IPFS_API_HTTP} timeout=${IPFS_READY_TIMEOUT_SECONDS}s"

if [ "$START_CLUSTER" = "true" ]; then
  if [ "$START_CLUSTER_ARGS" != "${START_CLUSTER_ARGS/--build/}" ]; then
    log "Detected stale or missing consensus jar; ensuring single-cluster launch rebuilds jars"
  fi
  log "Starting single cluster via start-cluster.sh ${START_CLUSTER_ARGS}"
  # shellcheck disable=SC2086
  "$LIFECYCLE_DIR/start-cluster.sh" $START_CLUSTER_ARGS 2>&1 | tee -a "$RUN_LOG"
else
  log "Skipping cluster start (START_CLUSTER=false)"
fi

wait_all_nodes_up 120 || fail "Cluster did not bring all nodes up"
wait_all_nodes_cluster_healthy 120 || fail "Cluster did not become healthy"
wait_cluster_queue_empty "baseline"
settle_http_idle "post-baseline queue drain"

write_batch "$PRIMARY_WALLET" "${ORGS[0]}" "$WRITE_COUNT_PER_ORG" "$PRIMARY_NORTH_FILE"
write_batch "$PRIMARY_WALLET" "${ORGS[1]}" "$WRITE_COUNT_PER_ORG" "$PRIMARY_SOUTH_FILE"
write_batch "$PRIMARY_WALLET" "${ORGS[2]}" "$WRITE_COUNT_PER_ORG" "$PRIMARY_ARCHIVE_FILE"
write_batch "$SECONDARY_WALLET" "${ORGS[0]}" "$WRITE_COUNT_PER_ORG" "$SECONDARY_NORTH_FILE"
write_batch "$SECONDARY_WALLET" "${ORGS[1]}" "$WRITE_COUNT_PER_ORG" "$SECONDARY_SOUTH_FILE"
write_batch "$SECONDARY_WALLET" "${ORGS[2]}" "$WRITE_COUNT_PER_ORG" "$SECONDARY_ARCHIVE_FILE"

wait_cluster_queue_empty "post-write"

wait_child_count_all_ports "$PRIMARY_NORTH_ROOT" "$WRITE_COUNT_PER_ORG" "primary north population"
wait_child_count_all_ports "$PRIMARY_SOUTH_ROOT" "$WRITE_COUNT_PER_ORG" "primary south population"
wait_child_count_all_ports "$PRIMARY_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "primary archive population"
wait_child_count_all_ports "$SECONDARY_NORTH_ROOT" "$WRITE_COUNT_PER_ORG" "secondary north population"
wait_child_count_all_ports "$SECONDARY_SOUTH_ROOT" "$WRITE_COUNT_PER_ORG" "secondary south population"
wait_child_count_all_ports "$SECONDARY_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "secondary archive population"
settle_http_idle "post-population count checks"

while IFS= read -r sample_path; do
  [ -n "$sample_path" ] || continue
  wait_path_visible_all_ports "$sample_path" "primary sample visibility"
done < <(sample_paths_from_file "$PRIMARY_NORTH_FILE" | awk '!seen[$0]++')

while IFS= read -r sample_path; do
  [ -n "$sample_path" ] || continue
  wait_path_visible_all_ports "$sample_path" "secondary sample visibility"
done < <(sample_paths_from_file "$SECONDARY_ARCHIVE_FILE" | awk '!seen[$0]++')

mapfile -t PRIMARY_INDIVIDUAL_DELETES < <(head -n 3 "$PRIMARY_NORTH_FILE")
mapfile -t SECONDARY_INDIVIDUAL_DELETES < <(head -n 3 "$SECONDARY_NORTH_FILE")

for path in "${PRIMARY_INDIVIDUAL_DELETES[@]}"; do
  delete_path_and_wait "$PRIMARY_WALLET" "$path" "$path"
  wait_path_absent_all_ports "$path" "primary individual delete"
done

for path in "${SECONDARY_INDIVIDUAL_DELETES[@]}"; do
  delete_path_and_wait "$SECONDARY_WALLET" "$path" "$path"
  wait_path_absent_all_ports "$path" "secondary individual delete"
done

wait_cluster_queue_empty "post-individual-delete"
wait_child_count_all_ports "$PRIMARY_NORTH_ROOT" "$((WRITE_COUNT_PER_ORG - 3))" "primary north after individual deletes"
wait_child_count_all_ports "$SECONDARY_NORTH_ROOT" "$((WRITE_COUNT_PER_ORG - 3))" "secondary north after individual deletes"

delete_path_and_wait "$PRIMARY_WALLET" "$PRIMARY_SOUTH_ROOT" "$PRIMARY_SOUTH_ROOT"
delete_path_and_wait "$SECONDARY_WALLET" "$SECONDARY_SOUTH_ROOT" "$SECONDARY_SOUTH_ROOT"

wait_path_absent_all_ports "$PRIMARY_SOUTH_ROOT" "primary subtree delete"
wait_path_absent_all_ports "$SECONDARY_SOUTH_ROOT" "secondary subtree delete"
wait_child_count_all_ports "$PRIMARY_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "primary archive survives subtree delete"
wait_child_count_all_ports "$SECONDARY_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "secondary archive survives subtree delete"

if [ "$RUN_STABILITY_SUITE" = "true" ]; then
  run_logged_script "single-cluster graceful failover smoke" \
    env FOLLOWER_TEST_WALLET="$FAILOVER_FOLLOWER_WALLET" LEADER_TEST_WALLET="$FAILOVER_LEADER_WALLET" \
    bash "$TESTS_DIR/stability/aeron-graceful-restart-smoke.sh"

  run_logged_script "single-cluster hard-crash failover smoke" \
    env FOLLOWER_TEST_WALLET="$FAILOVER_FOLLOWER_WALLET" LEADER_TEST_WALLET="$FAILOVER_LEADER_WALLET" \
    bash "$TESTS_DIR/stability/aeron-hard-crash-smoke.sh"

  run_logged_script "single-cluster follower catchup smoke" \
    env CATCHUP_WALLET="$CATCHUP_WALLET" CATCHUP_WRITE_COUNT=24 \
    bash "$TESTS_DIR/stability/aeron-follower-catchup-smoke.sh"

  run_logged_script "single-cluster quorum envelope smoke" \
    env QUORUM_ENVELOPE_WALLET="$QUORUM_ENVELOPE_WALLET" \
    bash "$TESTS_DIR/stability/aeron-quorum-envelope-smoke.sh"

  settle_http_idle "post-stability"

  SMOKE_BASE_URL="$(leader_base_url)"
  SMOKE_RESULT="$(submit_write_request "$SMOKE_BASE_URL" "$SMOKE_WALLET" "postStability" "[proposal-surfaces-single-cluster] post-stability")"
  SMOKE_STATUS="$(echo "$SMOKE_RESULT" | cut -d'|' -f1)"
  SMOKE_OP="$(echo "$SMOKE_RESULT" | cut -d'|' -f2)"
  SMOKE_PATH="$(echo "$SMOKE_RESULT" | cut -d'|' -f3)"
  SMOKE_BODY="$(echo "$SMOKE_RESULT" | cut -d'|' -f4-)"
  assert_accepted "$SMOKE_STATUS" "$SMOKE_BODY" "post-stability write"
  [ -n "$SMOKE_OP" ] || fail "post-stability write missing operationId"
  [ -n "$SMOKE_PATH" ] || fail "post-stability write missing storagePath"
  wait_operation_committed "$SMOKE_BASE_URL" "$SMOKE_OP" || fail "post-stability write did not commit"
  wait_path_visible_all_ports "$SMOKE_PATH" "post-stability visibility"
fi

delete_path_and_wait "$SECONDARY_WALLET" "$SECONDARY_WALLET_ROOT" "$SECONDARY_WALLET_ROOT"
wait_path_absent_all_ports "$SECONDARY_WALLET_ROOT" "secondary full namespace delete"
wait_path_absent_all_ports "$SECONDARY_NORTH_ROOT" "secondary north removed with wallet namespace delete"
wait_path_absent_all_ports "$SECONDARY_ARCHIVE_ROOT" "secondary archive removed with wallet namespace delete"
wait_child_count_all_ports "$PRIMARY_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "primary archive still intact after secondary delete"

wait_cluster_queue_empty "final"

"$LIFECYCLE_DIR/status-cluster.sh" 2>&1 | tee -a "$RUN_LOG"

log "SUCCESS proposal-surfaces-single-cluster completed"
log "Artifacts written to ${ARTIFACT_ROOT}"
