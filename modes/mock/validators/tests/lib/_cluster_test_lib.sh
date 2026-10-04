#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
LIFECYCLE_DIR="${LIFECYCLE_DIR:-$(cd "$TESTS_DIR/../lifecycle" && pwd)}"
MEMBER_SCRIPT="${MEMBER_SCRIPT:-$LIFECYCLE_DIR/member.sh}"
VALIDATOR_SCRIPT="${VALIDATOR_SCRIPT:-$TESTS_DIR/../debug/run-validator-node.sh}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
# shellcheck source=../../lifecycle/lib/root-guard.sh
source "$LIFECYCLE_DIR/lib/root-guard.sh"
# Transactions come from the shared conformant builder `oak-chain tx` (test keys we hold).
# shellcheck source=../../../lib/oak-tx.sh
source "$LIB_DIR/../../../lib/oak-tx.sh"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
HOST="${HOST:-http://127.0.0.1}"
OAK_CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
OAK_VALIDATOR_HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
OAK_VALIDATOR_HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
OAK_VALIDATOR_AUTH_TOKEN="${OAK_VALIDATOR_AUTH_TOKEN:-}"
WRITE_WAIT_SECONDS="${WRITE_WAIT_SECONDS:-90}"
ELECTION_WAIT_SECONDS="${ELECTION_WAIT_SECONDS:-60}"
REJOIN_WAIT_SECONDS="${REJOIN_WAIT_SECONDS:-90}"
GRACEFUL_STOP_WAIT_SECONDS="${GRACEFUL_STOP_WAIT_SECONDS:-30}"
CRASH_STOP_WAIT_SECONDS="${CRASH_STOP_WAIT_SECONDS:-10}"
LOCAL_HEALTH_PATH="${LOCAL_HEALTH_PATH:-/health/local}"

PORTS=()
for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  PORTS+=($((OAK_VALIDATOR_HTTP_BASE_PORT + (node * OAK_VALIDATOR_HTTP_PORT_STEP))))
done

HEADER_ARGS=()
if [ -n "$OAK_VALIDATOR_AUTH_TOKEN" ]; then
  HEADER_ARGS+=(-H "Authorization: Bearer ${OAK_VALIDATOR_AUTH_TOKEN}")
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

node_port() {
  local node=$1
  echo $((OAK_VALIDATOR_HTTP_BASE_PORT + (node * OAK_VALIDATOR_HTTP_PORT_STEP)))
}

node_base() {
  local node=$1
  printf '%s:%s' "$HOST" "$(node_port "$node")"
}

port_to_node() {
  local port=$1
  echo $(((port - OAK_VALIDATOR_HTTP_BASE_PORT) / OAK_VALIDATOR_HTTP_PORT_STEP))
}

node_pid_file() {
  local node=$1
  echo "$PID_DIR/validator-${node}.pid"
}

read_pid_file() {
  local pid_file=$1
  if [ -f "$pid_file" ]; then
    tr -d '[:space:]' < "$pid_file" 2>/dev/null || true
  fi
}

is_pid_alive() {
  local pid=$1
  [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1
}

wait_for_pid_exit() {
  local pid=$1
  local timeout_seconds=$2
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if ! is_pid_alive "$pid"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

http_code() {
  local url=$1
  local body_file
  body_file=$(mktemp)
  local code
  if [ "${#HEADER_ARGS[@]}" -gt 0 ]; then
    code=$(curl -s -o "$body_file" -w "%{http_code}" "${HEADER_ARGS[@]}" "$url" || echo "000")
  else
    code=$(curl -s -o "$body_file" -w "%{http_code}" "$url" || echo "000")
  fi
  rm -f "$body_file"
  echo "$code"
}

fetch_json() {
  local url=$1
  if [ "${#HEADER_ARGS[@]}" -gt 0 ]; then
    curl -s "${HEADER_ARGS[@]}" "$url"
  else
    curl -s "$url"
  fi
}

json_field() {
  local json=$1
  local field=$2
  python3 -c '
import json
import sys

field = sys.argv[1]
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

cur = data
for part in field.split("."):
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print(str(cur).lower())
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
' "$field" <<<"$json"
}

node_up() {
  local node=$1
  [ "$(http_code "$(node_base "$node")${LOCAL_HEALTH_PATH}")" = "200" ]
}

wait_for_http_state() {
  local url=$1
  local expected=$2
  local timeout_seconds=$3
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local code
    code=$(http_code "$url")
    if [ "$expected" = "up" ] && [ "$code" = "200" ]; then
      return 0
    fi
    if [ "$expected" = "down" ] && [ "$code" != "200" ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

wait_node_up() {
  local node=$1
  wait_for_http_state "$(node_base "$node")${LOCAL_HEALTH_PATH}" up "$REJOIN_WAIT_SECONDS"
}

wait_node_down() {
  local node=$1
  wait_for_http_state "$(node_base "$node")${LOCAL_HEALTH_PATH}" down 30
}

node_role() {
  local node=$1
  local json
  json=$(fetch_json "$(node_base "$node")/v1/consensus/status" 2>/dev/null || echo "{}")
  local role
  role=$(json_field "$json" "currentRole")
  if [ -n "$role" ]; then
    echo "$role"
    return
  fi
  json=$(fetch_json "$(node_base "$node")/health" 2>/dev/null || echo "{}")
  json_field "$json" "currentRole"
}

wait_for_role() {
  local node=$1
  local expected=$2
  local timeout_seconds=$3
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if [ "$(node_role "$node")" = "$expected" ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

find_leader_port() {
  local port
  for port in "${PORTS[@]}"; do
    local node
    node=$(port_to_node "$port")
    if ! node_up "$node"; then
      continue
    fi
    if [ "$(node_role "$node")" = "LEADER" ]; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

wait_for_distinct_leader() {
  local previous_port=$1
  local timeout_seconds=${2:-$ELECTION_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local leader
    leader=$(find_leader_port || true)
    if [ -n "$leader" ] && [ "$leader" != "$previous_port" ]; then
      echo "$leader"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# Fault actions (risk class C) go through lifecycle/member.sh, which checks PID identity
# (the pid's command line must name this root's validator-N store), refuses to start over a
# port held by another root, and enforces the launch-record membership. They are refused on
# the protected live root unless OAK_ALLOW_LIVE_ROOT=1. member.sh logs a start to
# $LOG_DIR/start-validator-N.log (the old in-lib launcher used rejoin-validator-N.log).
member_action() {
  CLUSTER_RUNTIME_ROOT="$CLUSTER_RUNTIME_ROOT" PID_DIR="$PID_DIR" LOG_DIR="$LOG_DIR" \
    VALIDATOR_SCRIPT="$VALIDATOR_SCRIPT" "$MEMBER_SCRIPT" "$@"
}

require_fault_root() {
  oak_guard_require_disposable_root "$CLUSTER_RUNTIME_ROOT" "$1"
}

start_node() {
  local node=$1
  mkdir -p "$PID_DIR" "$LOG_DIR"
  log "Starting validator-${node} via member.sh"
  member_action start "$node"
}

graceful_stop_node() {
  local node=$1
  require_fault_root "graceful stop of validator-${node} (SIGTERM)" || return 1
  log "Gracefully stopping validator-${node} via member.sh (SIGTERM, ${GRACEFUL_STOP_WAIT_SECONDS}s, no SIGKILL escalation)"
  if ! STOP_WAIT_SECONDS="$GRACEFUL_STOP_WAIT_SECONDS" STOP_ESCALATE=false member_action stop "$node"; then
    log "validator-${node} did not exit within ${GRACEFUL_STOP_WAIT_SECONDS}s after TERM"
    return 1
  fi
}

crash_stop_node() {
  local node=$1
  require_fault_root "hard crash of validator-${node} (SIGKILL)" || return 1
  log "Crashing validator-${node} via member.sh (SIGKILL)"
  KILL_WAIT_SECONDS="$CRASH_STOP_WAIT_SECONDS" member_action kill "$node"
}

stop_node() {
  local node=$1
  local mode=${2:-crash}
  case "$mode" in
    graceful)
      graceful_stop_node "$node"
      ;;
    crash|hard|kill)
      crash_stop_node "$node"
      ;;
    *)
      log "Unknown stop mode '${mode}' for validator-${node}"
      return 1
      ;;
  esac
}

sharding_local_prefix_range() {
  python3 - <<'PY'
import os
import re

opts = os.environ.get("EXTRA_JAVA_OPTS", "")
match = re.search(r"-Doak\.sharding\.local\.prefixes=([0-9a-fA-F]{2})(?:-([0-9a-fA-F]{2}))?", opts)
if match:
    start = match.group(1).lower()
    end = (match.group(2) or match.group(1)).lower()
    print(f"{start}|{end}")
PY
}

# Shard-local test wallet (a key we hold) whose address starts with the given byte.
wallet_for_prefix_decimal() {
  local prefix_decimal=$1
  test_wallet_for_prefix "$(printf '%02x' "$prefix_decimal")"
}

# A held test wallet for this cluster's shard: inside -Doak.sharding.local.prefixes when set
# (start + offset), otherwise the test key with the default wallet's first byte (see
# modes/mock/lib/oak-tx.sh test_wallet_for_address).
resolve_wallet_for_local_shard() {
  local default_wallet="$1"
  local offset="${2:-0}"
  local prefix_range
  prefix_range="$(sharding_local_prefix_range || true)"

  if [ -n "$prefix_range" ]; then
    local start_hex end_hex start_decimal end_decimal target_decimal
    start_hex="${prefix_range%%|*}"
    end_hex="${prefix_range##*|}"
    start_decimal=$((16#$start_hex))
    end_decimal=$((16#$end_hex))
    target_decimal=$((start_decimal + offset))
    if [ "$target_decimal" -gt "$end_decimal" ]; then
      target_decimal="$end_decimal"
    fi
    wallet_for_prefix_decimal "$target_decimal"
    return 0
  fi

  test_wallet_for_address "$default_wallet"
}

# Conformant write (modes/mock/TRANSACTION-CONTRACT.md) built by `oak-chain tx write`: signed by
# the wallet's test key over exactly the message (label), ethereumTxHash = proposalId (mock
# settlement), no paymentTier. Prints code|operationId|storagePath|body. A wallet we hold no key
# for prints 000 and returns 1.
submit_write() {
  local base=$1
  local wallet=$2
  local label=$3
  local organization=${4:-}
  local form
  local tx_args=(write --message "$label" --content-type page)
  if [ -n "$organization" ]; then
    tx_args+=(--organization "$organization")
  fi
  if ! form=$(oak_tx_as "$wallet" "${tx_args[@]}"); then
    printf '000|||{"error":"could not build a signed write for wallet %s"}\n' "$wallet"
    return 1
  fi
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "$base/v1/propose-write" \
    ${HEADER_ARGS[@]+"${HEADER_ARGS[@]}"} \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-binary "$form")
  local code
  code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')
  local op_id
  op_id=$(json_field "$body" "operationId")
  local storage_path
  storage_path=$(json_field "$body" "storagePath")
  printf '%s|%s|%s|%s\n' "$code" "$op_id" "$storage_path" "$body"
}

# Conformant delete built by `oak-chain tx delete`: signed by the wallet's test key over exactly
# contentPath. Prints code|operationId|body.
submit_delete() {
  local base=$1
  local wallet=$2
  local storage_path=$3
  local form
  if ! form=$(oak_tx_as "$wallet" delete --content-path "$storage_path"); then
    printf '000||{"error":"could not build a signed delete for wallet %s"}\n' "$wallet"
    return 1
  fi
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "$base/v1/propose-delete" \
    ${HEADER_ARGS[@]+"${HEADER_ARGS[@]}"} \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-binary "$form")
  local code
  code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')
  local op_id
  op_id=$(json_field "$body" "operationId")
  printf '%s|%s|%s\n' "$code" "$op_id" "$body"
}

wait_operation_committed() {
  local base=$1
  local operation_id=$2
  local timeout_seconds=${3:-$WRITE_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local body
    body=$(fetch_json "$base/v1/ops/operations/$operation_id" 2>/dev/null || echo "{}")
    local state
    state=$(json_field "$body" "state")
    case "$state" in
      COMMITTED)
        return 0
        ;;
      FAILED|REJECTED|TIMED_OUT)
        log "Operation ${operation_id} ended in ${state}: $body"
        return 1
        ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log "Operation ${operation_id} timed out after ${timeout_seconds}s"
  return 1
}

encode_path() {
  printf '%s' "$1" | jq -sRr @uri
}

path_visible() {
  local node=$1
  local storage_path=$2
  local encoded
  encoded=$(encode_path "$storage_path")
  local body
  body=$(fetch_json "$(node_base "$node")/api/explore?path=${encoded}" 2>/dev/null || echo "{}")
  [ "$(json_field "$body" "path")" = "$storage_path" ]
}

path_absent() {
  local node=$1
  local storage_path=$2
  local encoded
  encoded=$(encode_path "$storage_path")
  [ "$(http_code "$(node_base "$node")/api/explore?path=${encoded}")" = "404" ]
}

wait_path_visible() {
  local node=$1
  local storage_path=$2
  local timeout_seconds=${3:-$REJOIN_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if path_visible "$node" "$storage_path"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

wait_path_absent() {
  local node=$1
  local storage_path=$2
  local timeout_seconds=${3:-$REJOIN_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if path_absent "$node" "$storage_path"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

wait_all_nodes_up() {
  local timeout_seconds=${1:-$REJOIN_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local all_up=true
    local node
    for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
      if ! node_up "$node"; then
        all_up=false
        break
      fi
    done
    if [ "$all_up" = true ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

cluster_healthy() {
  local node=$1
  local body
  body=$(fetch_json "$(node_base "$node")/health" 2>/dev/null || echo "{}")
  [ "$(json_field "$body" "clusterHealthy")" = "true" ]
}

wait_all_nodes_cluster_healthy() {
  local timeout_seconds=${1:-$REJOIN_WAIT_SECONDS}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local all_healthy=true
    local node
    for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
      if ! node_up "$node" || ! cluster_healthy "$node"; then
        all_healthy=false
        break
      fi
    done
    if [ "$all_healthy" = true ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}
