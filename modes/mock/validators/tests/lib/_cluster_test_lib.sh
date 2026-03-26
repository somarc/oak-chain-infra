#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
VALIDATOR_SCRIPT="${VALIDATOR_SCRIPT:-$TESTS_DIR/../debug/run-validator-node.sh}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
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

node_aeron_media_dir() {
  local node=$1
  local cluster_name="${CLUSTER_NAME:-single-cluster}"
  if [ -n "${AERON_DIR_BASE:-}" ]; then
    echo "${AERON_DIR_BASE%/}-${node}-driver"
    return
  fi
  if [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
    echo "${AERON_RAMDISK_ROOT%/}/${cluster_name}/aeron-media-${node}-driver"
    return
  fi
  echo "${CLUSTER_RUNTIME_ROOT}/validator-${node}/aeron-media-${node}-driver"
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

wait_for_pid_file_value() {
  local pid_file=$1
  local timeout_seconds=${2:-5}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local pid
    pid=$(read_pid_file "$pid_file")
    if [ -n "$pid" ]; then
      echo "$pid"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

launch_detached_process() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >>"$log_file" 2>&1 &
    echo $! > "$pid_file"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$pid_file" "$log_file" "$@" <<'PY'
import os
import sys

pid_file = sys.argv[1]
log_file = sys.argv[2]
cmd = sys.argv[3:]

pid = os.fork()
if pid > 0:
    os._exit(0)

os.setsid()

pid = os.fork()
if pid > 0:
    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{pid}\n")
    os._exit(0)

with open(log_file, "ab", buffering=0) as log:
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
os.execvp(cmd[0], cmd)
PY
    wait_for_pid_file_value "$pid_file" >/dev/null
    return $?
  fi

  nohup "$@" >>"$log_file" 2>&1 &
  echo $! > "$pid_file"
}

start_node() {
  local node=$1
  mkdir -p "$PID_DIR" "$LOG_DIR"
  local pid_file
  pid_file=$(node_pid_file "$node")
  local aeron_media_dir
  aeron_media_dir=$(node_aeron_media_dir "$node")
  if [ -d "$aeron_media_dir" ]; then
    rm -rf "$aeron_media_dir"
  fi
  rm -f "$pid_file"
  launch_detached_process "$pid_file" "$LOG_DIR/rejoin-validator-${node}.log" \
    "$VALIDATOR_SCRIPT" "$node"
  local pid
  pid=$(read_pid_file "$pid_file")
  echo "$pid" >"$pid_file"
  log "Started validator-${node} (pid=${pid})"
}

graceful_stop_node() {
  local node=$1
  local pid_file
  pid_file=$(node_pid_file "$node")
  local pid
  pid=$(read_pid_file "$pid_file")
  if ! is_pid_alive "$pid"; then
    log "validator-${node} already down"
    rm -f "$pid_file"
    return 0
  fi
  log "Gracefully stopping validator-${node} (pid=${pid})"
  kill "$pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$pid" "$GRACEFUL_STOP_WAIT_SECONDS"; then
    log "validator-${node} did not exit within ${GRACEFUL_STOP_WAIT_SECONDS}s after TERM"
    return 1
  fi
  rm -f "$pid_file"
}

crash_stop_node() {
  local node=$1
  local pid_file
  pid_file=$(node_pid_file "$node")
  local pid
  pid=$(read_pid_file "$pid_file")
  if ! is_pid_alive "$pid"; then
    log "validator-${node} already down"
    rm -f "$pid_file"
    return 0
  fi
  log "Crashing validator-${node} (pid=${pid})"
  kill -9 "$pid" >/dev/null 2>&1 || true
  wait_for_pid_exit "$pid" "$CRASH_STOP_WAIT_SECONDS" || true
  rm -f "$pid_file"
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

random_hex() {
  local bytes=$1
  openssl rand -hex "$bytes" 2>/dev/null || python3 - "$bytes" <<'PY'
import secrets
import sys
print(secrets.token_hex(int(sys.argv[1])))
PY
}

random_proposal_id() {
  printf '0x%s\n' "$(random_hex 32)"
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

wallet_for_prefix_decimal() {
  local prefix_decimal=$1
  printf '0x%02x%038x\n' "$prefix_decimal" 0
}

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

  printf '%s\n' "$default_wallet"
}

submit_write() {
  local base=$1
  local wallet=$2
  local label=$3
  local organization=${4:-}
  local tx_hash="0x$(random_hex 32)"
  local signature="0x$(random_hex 65)"
  local proposal_id
  proposal_id=$(random_proposal_id)
  local response
  local curl_args=(
    curl -s -w "\n%{http_code}" -X POST "$base/v1/propose-write"
    "${HEADER_ARGS[@]}"
    -H "Content-Type: application/x-www-form-urlencoded"
    -d "walletAddress=${wallet}"
    -d "proposalId=${proposal_id}"
    -d "ethereumTxHash=${tx_hash}"
    -d "contentType=page"
    -d "message=${label}"
    -d "signature=${signature}"
    -d "paymentTier=standard"
  )
  if [ -n "$organization" ]; then
    curl_args+=(-d "organization=${organization}")
  fi
  response=$("${curl_args[@]}")
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

submit_delete() {
  local base=$1
  local wallet=$2
  local storage_path=$3
  local tx_hash="0x$(random_hex 32)"
  local signature="0x$(random_hex 65)"
  local proposal_id
  proposal_id=$(random_proposal_id)
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "$base/v1/propose-delete" \
    "${HEADER_ARGS[@]}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "walletAddress=${wallet}" \
    --data-urlencode "proposalId=${proposal_id}" \
    --data-urlencode "signature=${signature}" \
    --data-urlencode "contentPath=${storage_path}" \
    --data-urlencode "ethereumTxHash=${tx_hash}")
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
