#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

FOLLOWER_STOP_MODE="${FOLLOWER_STOP_MODE:-${FAILOVER_STOP_MODE:-crash}}"
LEADER_STOP_MODE="${LEADER_STOP_MODE:-${FAILOVER_STOP_MODE:-crash}}"
POST_REJOIN_SETTLE_SECONDS="${POST_REJOIN_SETTLE_SECONDS:-45}"
FOLLOWER_TEST_WALLET="${FOLLOWER_TEST_WALLET:-}"
LEADER_TEST_WALLET="${LEADER_TEST_WALLET:-}"
DEFAULT_FOLLOWER_TEST_WALLET="0x1111111111111111111111111111111111111111"
DEFAULT_LEADER_TEST_WALLET="0x2222222222222222222222222222222222222222"
STOPPED_NODES=()

derive_local_prefix_range() {
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

resolve_failover_wallets() {
  if [ -n "$FOLLOWER_TEST_WALLET" ] && [ -n "$LEADER_TEST_WALLET" ]; then
    return 0
  fi

  local prefix_range
  prefix_range="$(derive_local_prefix_range || true)"
  if [ -n "$prefix_range" ]; then
    local start_hex end_hex start_decimal end_decimal leader_decimal
    start_hex="${prefix_range%%|*}"
    end_hex="${prefix_range##*|}"
    start_decimal=$((16#$start_hex))
    end_decimal=$((16#$end_hex))
    leader_decimal=$((start_decimal + 1))
    if [ "$leader_decimal" -gt "$end_decimal" ]; then
      leader_decimal="$start_decimal"
    fi
    FOLLOWER_TEST_WALLET="${FOLLOWER_TEST_WALLET:-$(wallet_for_prefix_decimal "$start_decimal")}"
    LEADER_TEST_WALLET="${LEADER_TEST_WALLET:-$(wallet_for_prefix_decimal "$leader_decimal")}"
    return 0
  fi

  FOLLOWER_TEST_WALLET="${FOLLOWER_TEST_WALLET:-$DEFAULT_FOLLOWER_TEST_WALLET}"
  LEADER_TEST_WALLET="${LEADER_TEST_WALLET:-$DEFAULT_LEADER_TEST_WALLET}"
}

restore_cluster() {
  local node
  for node in "${STOPPED_NODES[@]}"; do
    if ! node_up "$node"; then
      start_node "$node" || true
    fi
  done
  wait_all_nodes_up 90 || true
}
trap restore_cluster EXIT

record_stopped_node() {
  local node=$1
  local existing
  for existing in "${STOPPED_NODES[@]}"; do
    if [ "$existing" = "$node" ]; then
      return 0
    fi
  done
  STOPPED_NODES+=("$node")
}

resolve_failover_wallets
log "FAILOVER_TEST wallets follower=${FOLLOWER_TEST_WALLET} leader=${LEADER_TEST_WALLET}"

baseline_leader_port=$(find_leader_port || true)
if [ -z "$baseline_leader_port" ]; then
  log "No leader detected in healthy cluster"
  exit 1
fi

log "BASELINE leader=${baseline_leader_port}"
for port in "${PORTS[@]}"; do
  node=$(port_to_node "$port")
  log "BASELINE port=${port} role=$(node_role "$node")"
done

leader_node=$(port_to_node "$baseline_leader_port")
follower_node=""
for candidate in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$candidate" -ne "$leader_node" ]; then
    follower_node="$candidate"
    break
  fi
done

if [ -z "$follower_node" ]; then
  log "Could not determine follower node"
  exit 1
fi

follower_port=$(node_port "$follower_node")
stop_node "$follower_node" "$FOLLOWER_STOP_MODE"
record_stopped_node "$follower_node"
wait_node_down "$follower_node"
log "FOLLOWER_TEST stop node=${follower_node} port=${follower_port} mode=${FOLLOWER_STOP_MODE}"

submit_result=$(submit_write "${HOST}:${baseline_leader_port}" "$FOLLOWER_TEST_WALLET" "FOLLOWER_FAILOVER_$(date +%s)")
submit_code=$(echo "$submit_result" | cut -d'|' -f1)
follower_op=$(echo "$submit_result" | cut -d'|' -f2)
follower_path=$(echo "$submit_result" | cut -d'|' -f3)

if [ "$submit_code" != "200" ] && [ "$submit_code" != "202" ]; then
  submit_body=$(echo "$submit_result" | cut -d'|' -f4-)
  log "FOLLOWER_TEST submit failed http=${submit_code} wallet=${FOLLOWER_TEST_WALLET} body=${submit_body}"
  exit 1
fi

wait_operation_committed "${HOST}:${baseline_leader_port}" "$follower_op"
log "FOLLOWER_TEST surviving_leader=${baseline_leader_port}"

for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$node" = "$follower_node" ]; then
    continue
  fi
  if ! wait_path_visible "$node" "$follower_path" 30; then
    log "FOLLOWER_TEST path missing on node=${node}"
    exit 1
  fi
  log "FOLLOWER_TEST visible port=$(node_port "$node")"
done

start_node "$follower_node"
wait_node_up "$follower_node"
wait_for_role "$follower_node" "FOLLOWER" 90
if ! wait_path_visible "$follower_node" "$follower_path" 90; then
  log "FOLLOWER_TEST rejoined node did not catch up path=${follower_path}"
  exit 1
fi
log "FOLLOWER_TEST rejoined port=${follower_port} role=$(node_role "$follower_node") path=${follower_path}"

leader_port_before_failover=$(find_leader_port || true)
if [ -z "$leader_port_before_failover" ]; then
  log "Leader missing before leader-failover phase"
  exit 1
fi
leader_node_before_failover=$(port_to_node "$leader_port_before_failover")
stop_node "$leader_node_before_failover" "$LEADER_STOP_MODE"
record_stopped_node "$leader_node_before_failover"
wait_node_down "$leader_node_before_failover"
log "LEADER_TEST stop node=${leader_node_before_failover} port=${leader_port_before_failover} mode=${LEADER_STOP_MODE}"

new_leader_port=$(wait_for_distinct_leader "$leader_port_before_failover" 90 || true)
if [ -z "$new_leader_port" ]; then
  log "LEADER_TEST new leader was not elected"
  exit 1
fi
log "LEADER_TEST new_leader=${new_leader_port}"

leader_submit=$(submit_write "${HOST}:${new_leader_port}" "$LEADER_TEST_WALLET" "LEADER_FAILOVER_$(date +%s)")
leader_submit_code=$(echo "$leader_submit" | cut -d'|' -f1)
leader_op=$(echo "$leader_submit" | cut -d'|' -f2)
leader_path=$(echo "$leader_submit" | cut -d'|' -f3)

if [ "$leader_submit_code" != "200" ] && [ "$leader_submit_code" != "202" ]; then
  leader_submit_body=$(echo "$leader_submit" | cut -d'|' -f4-)
  log "LEADER_TEST submit failed http=${leader_submit_code} wallet=${LEADER_TEST_WALLET} body=${leader_submit_body}"
  exit 1
fi

wait_operation_committed "${HOST}:${new_leader_port}" "$leader_op"

for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$node" = "$leader_node_before_failover" ]; then
    continue
  fi
  if ! wait_path_visible "$node" "$leader_path" 30; then
    log "LEADER_TEST path missing on node=${node}"
    exit 1
  fi
  log "LEADER_TEST visible port=$(node_port "$node")"
done

start_node "$leader_node_before_failover"
wait_node_up "$leader_node_before_failover"
wait_for_role "$leader_node_before_failover" "FOLLOWER" 90
if ! wait_path_visible "$leader_node_before_failover" "$leader_path" 90; then
  log "LEADER_TEST rejoined node did not catch up path=${leader_path}"
  exit 1
fi
log "LEADER_TEST rejoined port=${leader_port_before_failover} role=$(node_role "$leader_node_before_failover") path=${leader_path}"

if ! wait_all_nodes_up "$POST_REJOIN_SETTLE_SECONDS"; then
  log "POST_REJOIN cluster did not keep all nodes UP"
  exit 1
fi

if ! wait_all_nodes_cluster_healthy "$POST_REJOIN_SETTLE_SECONDS"; then
  log "POST_REJOIN cluster did not return to healthy state"
  exit 1
fi

final_leader_port=$(find_leader_port || true)
if [ -z "$final_leader_port" ]; then
  log "POST_REJOIN no leader detected after recovery window"
  exit 1
fi

for port in "${PORTS[@]}"; do
  node=$(port_to_node "$port")
  log "POST_REJOIN port=${port} role=$(node_role "$node")"
done

log "SUCCESS follower_rejoin_op=${follower_op} leader_rejoin_op=${leader_op}"
