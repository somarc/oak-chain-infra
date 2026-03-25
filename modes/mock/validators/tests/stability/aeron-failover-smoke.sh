#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

FOLLOWER_STOP_MODE="${FOLLOWER_STOP_MODE:-${FAILOVER_STOP_MODE:-crash}}"
LEADER_STOP_MODE="${LEADER_STOP_MODE:-${FAILOVER_STOP_MODE:-crash}}"
POST_REJOIN_SETTLE_SECONDS="${POST_REJOIN_SETTLE_SECONDS:-45}"
FOLLOWER_TEST_WALLET="${FOLLOWER_TEST_WALLET:-0x1111111111111111111111111111111111111111}"
LEADER_TEST_WALLET="${LEADER_TEST_WALLET:-0x2222222222222222222222222222222222222222}"
STOPPED_NODES=()

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
  log "FOLLOWER_TEST submit failed http=${submit_code}"
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
  log "LEADER_TEST submit failed http=${leader_submit_code}"
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
