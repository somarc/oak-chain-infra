#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$TESTS_DIR/../lifecycle"
CONFIG_DIR="$TESTS_DIR/../config"
OAK_ROOT="$(cd "$TESTS_DIR/../../../../.." && pwd)"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x2-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x2-cluster-b.env}"

START_3X2="${START_3X2:-true}"
START_3X2_ARGS="${START_3X2_ARGS:---fresh}"
WRITE_COUNT_PER_ORG="${WRITE_COUNT_PER_ORG:-72}"
WRITE_WAIT_SECONDS="${WRITE_WAIT_SECONDS:-90}"
READ_TIMEOUT_SECONDS="${READ_TIMEOUT_SECONDS:-90}"
READ_POLL_INTERVAL_SECONDS="${READ_POLL_INTERVAL_SECONDS:-2}"
QUEUE_EMPTY_TIMEOUT_SECONDS="${QUEUE_EMPTY_TIMEOUT_SECONDS:-300}"
QUEUE_EMPTY_POLL_SECONDS="${QUEUE_EMPTY_POLL_SECONDS:-5}"
HTTP_IDLE_SETTLE_SECONDS="${HTTP_IDLE_SETTLE_SECONDS:-5}"
RATE_LIMIT_RETRY_MAX="${RATE_LIMIT_RETRY_MAX:-5}"
RATE_LIMIT_RETRY_FALLBACK_SECONDS="${RATE_LIMIT_RETRY_FALLBACK_SECONDS:-2}"
NO_QUORUM_RETRY_MAX="${NO_QUORUM_RETRY_MAX:-15}"
NO_QUORUM_RETRY_DELAY_SECONDS="${NO_QUORUM_RETRY_DELAY_SECONDS:-2}"
RUN_STABILITY_SUITE="${RUN_STABILITY_SUITE:-true}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/oak-proposal-surfaces-3x2-artifacts}"
RUN_LOG="${ARTIFACT_ROOT}/run.log"

# Defer IPFS lifecycle behavior to the cluster launcher. It will:
# - reuse an already-running host daemon when available
# - auto-start a daemon only when AUTO_START_IPFS=true and the API is unavailable
# - wait for API readiness before validator startup
export AUTO_START_IPFS="${AUTO_START_IPFS:-true}"
export IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"
export IPFS_READY_TIMEOUT_SECONDS="${IPFS_READY_TIMEOUT_SECONDS:-30}"

WALLET_A="${WALLET_A:-0x1100000000000000000000000000000000000000}"
WALLET_B="${WALLET_B:-0x8800000000000000000000000000000000000000}"
SMOKE_WALLET_A="${SMOKE_WALLET_A:-0x1200000000000000000000000000000000000000}"
SMOKE_WALLET_B="${SMOKE_WALLET_B:-0x8900000000000000000000000000000000000000}"
WALLET_A_FAILOVER_FOLLOWER="${WALLET_A_FAILOVER_FOLLOWER:-0x1111111111111111111111111111111111111111}"
WALLET_A_FAILOVER_LEADER="${WALLET_A_FAILOVER_LEADER:-0x2222222222222222222222222222222222222222}"
WALLET_A_QUORUM="${WALLET_A_QUORUM:-0x3333333333333333333333333333333333333333}"
WALLET_B_FAILOVER_FOLLOWER="${WALLET_B_FAILOVER_FOLLOWER:-0x8800000000000000000000000000000000000001}"
WALLET_B_FAILOVER_LEADER="${WALLET_B_FAILOVER_LEADER:-0x9900000000000000000000000000000000000002}"
WALLET_B_CATCHUP="${WALLET_B_CATCHUP:-0xaa00000000000000000000000000000000000003}"

A_ORGS=(AtlasNorth AtlasSouth AtlasArchive)
B_ORGS=(BeaconNorth BeaconSouth BeaconArchive)

REQUEST_STATUS=""
REQUEST_LOCATION=""
REQUEST_BODY=""

usage() {
  cat <<'EOF'
Usage: ./proposal-surfaces-3x2.sh [--skip-start] [--writes-per-org N] [--artifacts-dir PATH] [--skip-stability]

Bounded, non-load 3x2 mock-mode proposal coverage:
  - fresh 3x2 cluster bring-up (optional)
  - cross-cluster sharding smoke
  - a few hundred writes per wallet using organization-scoped subtrees
  - individual delete, subtree delete, and full wallet namespace delete
  - Aeron failover, catch-up, and quorum-loss stability probes

Environment:
  START_3X2=true|false
  START_3X2_ARGS="--fresh"         forwarded to lifecycle/start-3x2.sh
  WRITE_COUNT_PER_ORG=72           default = 216 writes per wallet across 3 orgs
  ARTIFACT_ROOT=/path/to/output
  RUN_STABILITY_SUITE=true|false
  SMOKE_WALLET_A=0x12...
  SMOKE_WALLET_B=0x89...
  HTTP_IDLE_SETTLE_SECONDS=5       quiet window after queue drain before smoke/writes
  RATE_LIMIT_RETRY_MAX=5           retry incidental 429s this many times per request
  RATE_LIMIT_RETRY_FALLBACK_SECONDS=2
  NO_QUORUM_RETRY_MAX=15          retry transient 503 no_quorum during induced recovery
  NO_QUORUM_RETRY_DELAY_SECONDS=2
  AUTO_START_IPFS=true|false       defer to start-cluster.sh (default true)
  IPFS_API_HTTP=http://127.0.0.1:5001
  IPFS_READY_TIMEOUT_SECONDS=30
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
    --skip-start)
      START_3X2=false
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

if ! [[ "$RATE_LIMIT_RETRY_MAX" =~ ^[0-9]+$ ]]; then
  fail "RATE_LIMIT_RETRY_MAX must be a non-negative integer"
fi

if ! [[ "$RATE_LIMIT_RETRY_FALLBACK_SECONDS" =~ ^[0-9]+$ ]] || [ "$RATE_LIMIT_RETRY_FALLBACK_SECONDS" -le 0 ]; then
  fail "RATE_LIMIT_RETRY_FALLBACK_SECONDS must be a positive integer"
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
  case " $START_3X2_ARGS " in
    *" $arg "*) ;;
    *)
      START_3X2_ARGS="${START_3X2_ARGS:+$START_3X2_ARGS }$arg"
      ;;
  esac
}

if [ "$START_3X2" = "true" ] && consensus_jar_is_stale; then
  ensure_start_arg "--build"
fi

random_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes" 2>/dev/null || python3 - "$bytes" <<'PY'
import secrets
import sys
print(secrets.token_hex(int(sys.argv[1])))
PY
}

random_proposal_id() {
  printf '0x%s\n' "$(random_hex 32)"
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

load_cluster_env() {
  local cluster_config="$1"
  set -a
  for cfg in "${BASE_CONFIGS[@]}" "$cluster_config"; do
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
    else
      fail "Missing config file: $cfg"
    fi
  done
  set +a
}

resolve_cluster() {
  local cluster_config="$1"
  (
    load_cluster_env "$cluster_config"
    printf '%s|%s|%s|%s|%s|%s\n' \
      "${OAK_CLUSTER_NAME:-unknown}" \
      "${OAK_CLUSTER_SIZE:-3}" \
      "${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}" \
      "${OAK_VALIDATOR_HTTP_PORT_STEP:-2}" \
      "${OPS_PROXY_PORT:-8787}" \
      "${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
  )
}

cluster_ports() {
  local cluster_size="$1"
  local http_base_port="$2"
  local http_port_step="$3"
  local node_count=3
  if [ "$cluster_size" = "5" ]; then
    node_count=5
  fi

  local idx
  for ((idx=0; idx<node_count; idx++)); do
    printf '%s\n' $((http_base_port + (idx * http_port_step)))
  done
}

current_role_on_port() {
  local port="$1"
  local body
  local role
  body="$(curl -s "http://127.0.0.1:${port}/v1/consensus/status" || true)"
  role="$(json_field "$body" "currentRole")"
  if [ -n "$role" ]; then
    printf '%s\n' "$role"
    return 0
  fi

  body="$(curl -s "http://127.0.0.1:${port}/health" || true)"
  json_field "$body" "currentRole"
}

resolve_leader_port() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local leader_port=""
    local leader_count=0
    local port
    while IFS= read -r port; do
      if [ "$(current_role_on_port "$port")" = "LEADER" ]; then
        leader_port="$port"
        leader_count=$((leader_count + 1))
      fi
    done < <(cluster_ports "$cluster_size" "$http_base_port" "$http_port_step")

    if [ "$leader_count" -eq 1 ] && [ -n "$leader_port" ]; then
      printf '%s\n' "$leader_port"
      return 0
    fi
    sleep "$READ_POLL_INTERVAL_SECONDS"
  done

  fail "${cluster_name} leader resolution timed out"
}

resolve_leader_base_url() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local leader_port
  leader_port="$(resolve_leader_port "$cluster_name" "$cluster_size" "$http_base_port" "$http_port_step")"
  printf 'http://127.0.0.1:%s\n' "$leader_port"
}

json_field() {
  local json="$1"
  local field="$2"
  JSON_INPUT="$json" python3 - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
raw = os.environ.get("JSON_INPUT", "")
try:
    cur = json.loads(raw)
except Exception:
    print("")
    sys.exit(0)

for part in field.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print("")
        sys.exit(0)

if isinstance(cur, bool):
    print(str(cur).lower())
elif cur is None:
    print("")
else:
    print(cur)
PY
}

encode_path() {
  printf '%s' "$1" | jq -sRr @uri
}

retry_after_seconds() {
  local header_file="$1"
  local retry_after
  retry_after="$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {print $2}' "$header_file" | tr -d '\r' | tail -n 1)"
  if [[ "$retry_after" =~ ^[0-9]+$ ]] && [ "$retry_after" -gt 0 ]; then
    printf '%s\n' "$retry_after"
    return 0
  fi
  printf '%s\n' "$RATE_LIMIT_RETRY_FALLBACK_SECONDS"
}

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
  local body_file
  local header_file
  local proposal_id
  local rate_limit_attempt=0
  local no_quorum_attempt=0
  body_file="$(mktemp)"
  header_file="$(mktemp)"
  proposal_id="$(random_proposal_id)"

  while :; do
    REQUEST_STATUS="$(curl -s -D "$header_file" -o "$body_file" -w "%{http_code}" \
      -X POST "${base_url}/v1/propose-write" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "walletAddress=${wallet}" \
      -d "proposalId=${proposal_id}" \
      -d "ethereumTxHash=0x$(random_hex 32)" \
      -d "organization=${organization}" \
      -d "contentType=page" \
      -d "message=${label}" \
      -d "signature=0x$(random_hex 65)" \
      -d "paymentTier=standard" || echo "000")"
    REQUEST_BODY="$(cat "$body_file")"
    REQUEST_LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' "$header_file" | tr -d '\r' | tail -n 1)"

    if [ "$REQUEST_STATUS" = "429" ] && [ "$rate_limit_attempt" -lt "$RATE_LIMIT_RETRY_MAX" ]; then
      rate_limit_attempt=$((rate_limit_attempt + 1))
      local delay_seconds
      delay_seconds="$(retry_after_seconds "$header_file")"
      log "RETRY ${label}: write received 429 (attempt ${rate_limit_attempt}/${RATE_LIMIT_RETRY_MAX}), sleeping ${delay_seconds}s"
      sleep "$delay_seconds"
      continue
    fi

    if is_no_quorum_response "$REQUEST_STATUS" "$REQUEST_BODY" &&
      [ "$no_quorum_attempt" -lt "$NO_QUORUM_RETRY_MAX" ]; then
      no_quorum_attempt=$((no_quorum_attempt + 1))
      log "RETRY ${label}: write received 503 no_quorum (attempt ${no_quorum_attempt}/${NO_QUORUM_RETRY_MAX}), sleeping ${NO_QUORUM_RETRY_DELAY_SECONDS}s"
      sleep "$NO_QUORUM_RETRY_DELAY_SECONDS"
      continue
    fi

    break
  done

  rm -f "$body_file" "$header_file"
}

submit_delete_request() {
  local base_url="$1"
  local wallet="$2"
  local content_path="$3"
  local body_file
  local header_file
  local proposal_id
  local rate_limit_attempt=0
  local no_quorum_attempt=0
  body_file="$(mktemp)"
  header_file="$(mktemp)"
  proposal_id="$(random_proposal_id)"

  while :; do
    REQUEST_STATUS="$(curl -s -D "$header_file" -o "$body_file" -w "%{http_code}" \
      -X POST "${base_url}/v1/propose-delete" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "walletAddress=${wallet}" \
      --data-urlencode "proposalId=${proposal_id}" \
      --data-urlencode "signature=0x$(random_hex 65)" \
      --data-urlencode "contentPath=${content_path}" \
      --data-urlencode "ethereumTxHash=0x$(random_hex 32)" || echo "000")"
    REQUEST_BODY="$(cat "$body_file")"
    REQUEST_LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' "$header_file" | tr -d '\r' | tail -n 1)"

    if [ "$REQUEST_STATUS" = "429" ] && [ "$rate_limit_attempt" -lt "$RATE_LIMIT_RETRY_MAX" ]; then
      rate_limit_attempt=$((rate_limit_attempt + 1))
      local delay_seconds
      delay_seconds="$(retry_after_seconds "$header_file")"
      log "RETRY delete ${content_path}: received 429 (attempt ${rate_limit_attempt}/${RATE_LIMIT_RETRY_MAX}), sleeping ${delay_seconds}s"
      sleep "$delay_seconds"
      continue
    fi

    if is_no_quorum_response "$REQUEST_STATUS" "$REQUEST_BODY" &&
      [ "$no_quorum_attempt" -lt "$NO_QUORUM_RETRY_MAX" ]; then
      no_quorum_attempt=$((no_quorum_attempt + 1))
      log "RETRY delete ${content_path}: received 503 no_quorum (attempt ${no_quorum_attempt}/${NO_QUORUM_RETRY_MAX}), sleeping ${NO_QUORUM_RETRY_DELAY_SECONDS}s"
      sleep "$NO_QUORUM_RETRY_DELAY_SECONDS"
      continue
    fi

    break
  done

  rm -f "$body_file" "$header_file"
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

assert_redirect() {
  local status="$1"
  local location="$2"
  local expected_prefix="$3"
  local label="$4"
  [ "$status" = "307" ] || fail "${label} expected 307, got ${status}. body=${REQUEST_BODY}"
  case "$location" in
    "${expected_prefix}"*)
      log "REDIRECT ${label}: ${location}"
      ;;
    *)
      fail "${label} expected redirect prefix ${expected_prefix}, got ${location}"
      ;;
  esac
}

wait_operation_committed() {
  local base_url="$1"
  local operation_id="$2"
  local label="$3"
  local deadline
  deadline=$((SECONDS + WRITE_WAIT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local body
    local state
    body="$(curl -s "${base_url}/v1/ops/operations/${operation_id}" || true)"
    state="$(json_field "$body" "state")"
    case "$state" in
      COMMITTED)
        log "COMMITTED ${label}: op=${operation_id}"
        return 0
        ;;
      FAILED|REJECTED|TIMED_OUT)
        fail "${label} ended in ${state}. body=${body}"
        ;;
    esac
    sleep 2
  done

  fail "${label} timed out waiting for COMMITTED state: op=${operation_id}"
}

queue_is_empty_on_port() {
  local port="$1"
  local body
  body="$(curl -s "http://127.0.0.1:${port}/v1/proposals/queue/stats" || true)"
  printf '%s' "$body" | jq -e '
    (.pendingCount // 0) == 0 and
    (.batchQueueSize // 0) == 0 and
    (.verifiedCount // 0) == 0 and
    (.mempoolPendingCount // 0) == 0 and
    (.persistencePendingChanges // 0) == 0 and
    (.backpressurePendingRawCount // 0) == 0
  ' >/dev/null 2>&1
}

wait_cluster_queue_empty() {
  local cluster_name="$1"
  shift
  local -a ports=("$@")
  local deadline
  deadline=$((SECONDS + QUEUE_EMPTY_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local all_empty=true
    local port
    for port in "${ports[@]}"; do
      if ! queue_is_empty_on_port "$port"; then
        all_empty=false
        break
      fi
    done
    if [ "$all_empty" = true ]; then
      log "QUEUE EMPTY ${cluster_name}: ports=${ports[*]}"
      return 0
    fi
    sleep "$QUEUE_EMPTY_POLL_SECONDS"
  done

  fail "Queue did not drain for ${cluster_name}: ports=${ports[*]}"
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
  shift 2
  local port
  for port in "$@"; do
    wait_path_visible_on_port "$port" "$path" "$label"
  done
}

wait_path_absent_all_ports() {
  local path="$1"
  local label="$2"
  shift 2
  local port
  for port in "$@"; do
    wait_path_absent_on_port "$port" "$path" "$label"
  done
}

wait_child_count_all_ports() {
  local path="$1"
  local expected_count="$2"
  local label="$3"
  shift 3
  local port
  for port in "$@"; do
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

write_batch() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local wallet="$5"
  local organization="$6"
  local count="$7"
  local output_file="$8"
  local idx
  local submit_url

  submit_url="$(resolve_leader_base_url "$cluster_name" "$cluster_size" "$http_base_port" "$http_port_step")"
  log "LEADER ${cluster_name} write batch ${organization}: ${submit_url}"

  : > "$output_file"
  for ((idx=1; idx<=count; idx++)); do
    local label
    local storage_path
    label="[proposal-surfaces-3x2] ${cluster_name}/${organization}/${idx}"
    submit_write_request "$submit_url" "$wallet" "$organization" "$label"
    assert_accepted "$REQUEST_STATUS" "$REQUEST_BODY" "${cluster_name} write ${organization} #${idx}"
    storage_path="$(json_field "$REQUEST_BODY" "storagePath")"
    [ -n "$storage_path" ] || fail "${cluster_name} write ${organization} #${idx} missing storagePath"
    printf '%s\n' "$storage_path" >> "$output_file"
    if [ $((idx % 24)) -eq 0 ] || [ "$idx" -eq "$count" ]; then
      log "WRITE SUBMIT ${cluster_name}/${organization}: ${idx}/${count}"
    fi
  done

  log "WRITE SUBMIT COMPLETE ${cluster_name}/${organization}: ${count} proposals accepted"
}

delete_path_and_wait() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local wallet="$5"
  local path="$6"
  local label="$7"
  local operation_id
  local submit_url

  submit_url="$(resolve_leader_base_url "$cluster_name" "$cluster_size" "$http_base_port" "$http_port_step")"
  log "LEADER ${cluster_name} delete ${label}: ${submit_url}"

  submit_delete_request "$submit_url" "$wallet" "$path"
  assert_accepted "$REQUEST_STATUS" "$REQUEST_BODY" "${cluster_name} delete ${label}"
  operation_id="$(json_field "$REQUEST_BODY" "operationId")"
  [ -n "$operation_id" ] || fail "${cluster_name} delete ${label} missing operationId"
  wait_operation_committed "$submit_url" "$operation_id" "${cluster_name} delete ${label}"
}

run_logged_script() {
  local description="$1"
  shift
  log "RUN ${description}"
  "$@" 2>&1 | tee -a "$RUN_LOG"
}

run_cluster_test() {
  local cluster_config="$1"
  local description="$2"
  shift 2
  log "RUN ${description}"
  (
    load_cluster_env "$cluster_config"
    "$@"
  ) 2>&1 | tee -a "$RUN_LOG"
}

A_INFO="$(resolve_cluster "$CLUSTER_A_CONFIG")"
B_INFO="$(resolve_cluster "$CLUSTER_B_CONFIG")"
IFS='|' read -r A_NAME A_SIZE A_HTTP_BASE A_HTTP_STEP A_OPS_PORT A_RUNTIME_ROOT <<<"$A_INFO"
IFS='|' read -r B_NAME B_SIZE B_HTTP_BASE B_HTTP_STEP B_OPS_PORT B_RUNTIME_ROOT <<<"$B_INFO"

mapfile -t A_PORTS < <(cluster_ports "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP")
mapfile -t B_PORTS < <(cluster_ports "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP")
ALL_PORTS=("${A_PORTS[@]}" "${B_PORTS[@]}")

A_BASE_URL="http://127.0.0.1:${A_HTTP_BASE}"
B_BASE_URL="http://127.0.0.1:${B_HTTP_BASE}"

A_NORTH_FILE="${ARTIFACT_ROOT}/wallet-a-atlas-north.paths"
A_SOUTH_FILE="${ARTIFACT_ROOT}/wallet-a-atlas-south.paths"
A_ARCHIVE_FILE="${ARTIFACT_ROOT}/wallet-a-atlas-archive.paths"
B_NORTH_FILE="${ARTIFACT_ROOT}/wallet-b-beacon-north.paths"
B_SOUTH_FILE="${ARTIFACT_ROOT}/wallet-b-beacon-south.paths"
B_ARCHIVE_FILE="${ARTIFACT_ROOT}/wallet-b-beacon-archive.paths"

A_NORTH_ROOT="$(wallet_org_content_path "$WALLET_A" "${A_ORGS[0]}")"
A_SOUTH_ROOT="$(wallet_org_content_path "$WALLET_A" "${A_ORGS[1]}")"
A_ARCHIVE_ROOT="$(wallet_org_content_path "$WALLET_A" "${A_ORGS[2]}")"
B_NORTH_ROOT="$(wallet_org_content_path "$WALLET_B" "${B_ORGS[0]}")"
B_SOUTH_ROOT="$(wallet_org_content_path "$WALLET_B" "${B_ORGS[1]}")"
B_ARCHIVE_ROOT="$(wallet_org_content_path "$WALLET_B" "${B_ORGS[2]}")"
B_WALLET_ROOT="$(wallet_root_path "$WALLET_B")"

log "Artifacts: ${ARTIFACT_ROOT}"
log "Cluster A: ${A_NAME} ports=${A_PORTS[*]} runtime=${A_RUNTIME_ROOT}"
log "Cluster B: ${B_NAME} ports=${B_PORTS[*]} runtime=${B_RUNTIME_ROOT}"
log "Write count per org: ${WRITE_COUNT_PER_ORG}"
log "Proposal wallets: A=${WALLET_A} B=${WALLET_B}"
log "Baseline smoke wallets: A=${SMOKE_WALLET_A} B=${SMOKE_WALLET_B}"
log "HTTP idle settle: ${HTTP_IDLE_SETTLE_SECONDS}s"
log "IPFS policy: AUTO_START_IPFS=${AUTO_START_IPFS} API=${IPFS_API_HTTP} timeout=${IPFS_READY_TIMEOUT_SECONDS}s"

if [ "$START_3X2" = "true" ]; then
  if [ "$START_3X2_ARGS" != "${START_3X2_ARGS/--build/}" ]; then
    log "Detected stale or missing consensus jar; ensuring 3x2 launch rebuilds jars"
  fi
  log "Starting fresh 3x2 cluster via start-3x2.sh ${START_3X2_ARGS}"
  # shellcheck disable=SC2086
  "$LIFECYCLE_DIR/start-3x2.sh" $START_3X2_ARGS 2>&1 | tee -a "$RUN_LOG"
else
  log "Skipping cluster start (START_3X2=false)"
fi

wait_cluster_queue_empty "cluster-a baseline" "${A_PORTS[@]}"
wait_cluster_queue_empty "cluster-b baseline" "${B_PORTS[@]}"
settle_http_idle "post-baseline queue drain"

run_logged_script "3x2 sharding baseline smoke" \
  env WALLET_A="$SMOKE_WALLET_A" WALLET_B="$SMOKE_WALLET_B" \
  bash "$TESTS_DIR/routing/sharding-3x2-smoke.sh"
settle_http_idle "post-sharding smoke"

write_batch "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "${A_ORGS[0]}" "$WRITE_COUNT_PER_ORG" "$A_NORTH_FILE"
write_batch "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "${A_ORGS[1]}" "$WRITE_COUNT_PER_ORG" "$A_SOUTH_FILE"
write_batch "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "${A_ORGS[2]}" "$WRITE_COUNT_PER_ORG" "$A_ARCHIVE_FILE"
write_batch "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "${B_ORGS[0]}" "$WRITE_COUNT_PER_ORG" "$B_NORTH_FILE"
write_batch "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "${B_ORGS[1]}" "$WRITE_COUNT_PER_ORG" "$B_SOUTH_FILE"
write_batch "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "${B_ORGS[2]}" "$WRITE_COUNT_PER_ORG" "$B_ARCHIVE_FILE"

wait_cluster_queue_empty "cluster-a post-write" "${A_PORTS[@]}"
wait_cluster_queue_empty "cluster-b post-write" "${B_PORTS[@]}"

wait_child_count_all_ports "$A_NORTH_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-a atlas north population" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$A_SOUTH_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-a atlas south population" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$A_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-a atlas archive population" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$B_NORTH_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-b beacon north population" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$B_SOUTH_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-b beacon south population" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$B_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-b beacon archive population" "${ALL_PORTS[@]}"
settle_http_idle "post-population count checks"

while IFS= read -r sample_path; do
  [ -n "$sample_path" ] || continue
  wait_path_visible_all_ports "$sample_path" "wallet-a sample visibility" "${ALL_PORTS[@]}"
done < <(sample_paths_from_file "$A_NORTH_FILE" | awk '!seen[$0]++')

while IFS= read -r sample_path; do
  [ -n "$sample_path" ] || continue
  wait_path_visible_all_ports "$sample_path" "wallet-b sample visibility" "${ALL_PORTS[@]}"
done < <(sample_paths_from_file "$B_ARCHIVE_FILE" | awk '!seen[$0]++')

A_FOREIGN_DELETE_PATH="$(head -n 1 "$A_NORTH_FILE")"
B_FOREIGN_DELETE_PATH="$(head -n 1 "$B_NORTH_FILE")"
submit_delete_request "$B_BASE_URL" "$WALLET_A" "$A_FOREIGN_DELETE_PATH"
assert_redirect "$REQUEST_STATUS" "$REQUEST_LOCATION" "${A_BASE_URL}/v1/propose-delete" "cluster-b foreign delete for wallet-a"
submit_delete_request "$A_BASE_URL" "$WALLET_B" "$B_FOREIGN_DELETE_PATH"
assert_redirect "$REQUEST_STATUS" "$REQUEST_LOCATION" "${B_BASE_URL}/v1/propose-delete" "cluster-a foreign delete for wallet-b"

mapfile -t A_INDIVIDUAL_DELETES < <(head -n 3 "$A_NORTH_FILE")
mapfile -t B_INDIVIDUAL_DELETES < <(head -n 3 "$B_NORTH_FILE")

for path in "${A_INDIVIDUAL_DELETES[@]}"; do
  delete_path_and_wait "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "$path" "$path"
  wait_path_absent_all_ports "$path" "wallet-a individual delete" "${ALL_PORTS[@]}"
done

for path in "${B_INDIVIDUAL_DELETES[@]}"; do
  delete_path_and_wait "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "$path" "$path"
  wait_path_absent_all_ports "$path" "wallet-b individual delete" "${ALL_PORTS[@]}"
done

wait_cluster_queue_empty "cluster-a post-individual-delete" "${A_PORTS[@]}"
wait_cluster_queue_empty "cluster-b post-individual-delete" "${B_PORTS[@]}"

wait_child_count_all_ports "$A_NORTH_ROOT" "$((WRITE_COUNT_PER_ORG - 3))" "wallet-a atlas north after individual deletes" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$B_NORTH_ROOT" "$((WRITE_COUNT_PER_ORG - 3))" "wallet-b beacon north after individual deletes" "${ALL_PORTS[@]}"

delete_path_and_wait "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "$A_SOUTH_ROOT" "$A_SOUTH_ROOT"
delete_path_and_wait "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "$B_SOUTH_ROOT" "$B_SOUTH_ROOT"

wait_path_absent_all_ports "$A_SOUTH_ROOT" "wallet-a subtree delete" "${ALL_PORTS[@]}"
wait_path_absent_all_ports "$B_SOUTH_ROOT" "wallet-b subtree delete" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$A_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-a archive survives subtree delete" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$B_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-b archive survives subtree delete" "${ALL_PORTS[@]}"

if [ "$RUN_STABILITY_SUITE" = "true" ]; then
  run_cluster_test "$CLUSTER_A_CONFIG" "cluster-a graceful failover smoke" \
    env FOLLOWER_TEST_WALLET="$WALLET_A_FAILOVER_FOLLOWER" LEADER_TEST_WALLET="$WALLET_A_FAILOVER_LEADER" \
    bash "$TESTS_DIR/stability/aeron-graceful-restart-smoke.sh"

  run_cluster_test "$CLUSTER_B_CONFIG" "cluster-b hard-crash failover smoke" \
    env FOLLOWER_TEST_WALLET="$WALLET_B_FAILOVER_FOLLOWER" LEADER_TEST_WALLET="$WALLET_B_FAILOVER_LEADER" \
    bash "$TESTS_DIR/stability/aeron-hard-crash-smoke.sh"

  run_cluster_test "$CLUSTER_B_CONFIG" "cluster-b follower catchup smoke" \
    env CATCHUP_WALLET="$WALLET_B_CATCHUP" CATCHUP_WRITE_COUNT=24 \
    bash "$TESTS_DIR/stability/aeron-follower-catchup-smoke.sh"

  run_cluster_test "$CLUSTER_A_CONFIG" "cluster-a quorum loss smoke" \
    env QUORUM_TEST_WALLET="$WALLET_A_QUORUM" \
    bash "$TESTS_DIR/stability/aeron-quorum-loss-smoke.sh"

  settle_http_idle "post-quorum recovery"
  run_logged_script "3x2 sharding post-stability smoke" \
    env WALLET_A="$SMOKE_WALLET_A" WALLET_B="$SMOKE_WALLET_B" \
    bash "$TESTS_DIR/routing/sharding-3x2-smoke.sh"
fi

delete_path_and_wait "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "$B_WALLET_ROOT" "$B_WALLET_ROOT"
wait_path_absent_all_ports "$B_WALLET_ROOT" "wallet-b full namespace delete" "${ALL_PORTS[@]}"
wait_path_absent_all_ports "$B_NORTH_ROOT" "wallet-b north removed with wallet namespace delete" "${ALL_PORTS[@]}"
wait_path_absent_all_ports "$B_ARCHIVE_ROOT" "wallet-b archive removed with wallet namespace delete" "${ALL_PORTS[@]}"
wait_child_count_all_ports "$A_ARCHIVE_ROOT" "$WRITE_COUNT_PER_ORG" "wallet-a archive still intact after wallet-b delete" "${ALL_PORTS[@]}"

wait_cluster_queue_empty "cluster-a final" "${A_PORTS[@]}"
wait_cluster_queue_empty "cluster-b final" "${B_PORTS[@]}"

"$LIFECYCLE_DIR/status-3x2.sh" 2>&1 | tee -a "$RUN_LOG"

log "SUCCESS proposal-surfaces-3x2 completed"
log "Artifacts written to ${ARTIFACT_ROOT}"
