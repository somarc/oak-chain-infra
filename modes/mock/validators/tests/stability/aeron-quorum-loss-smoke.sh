#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

QUORUM_STOP_MODE="${QUORUM_STOP_MODE:-crash}"
QUORUM_TEST_WALLET="${QUORUM_TEST_WALLET:-0x3333333333333333333333333333333333333333}"
STOPPED_NODES=()

restore_cluster() {
  local node
  for node in "${STOPPED_NODES[@]}"; do
    if ! node_up "$node"; then
      start_node "$node" || true
    fi
  done
  if ! wait_all_nodes_up 90; then
    log "QUORUM_TEST recovery timed out waiting for all nodes up"
    return 1
  fi
  if ! wait_all_nodes_cluster_healthy 120; then
    log "QUORUM_TEST recovery timed out waiting for clusterHealthy=true on all nodes"
    return 1
  fi
  local recovered_leader
  recovered_leader=$(find_leader_port || true)
  if [ -z "$recovered_leader" ]; then
    log "QUORUM_TEST recovery did not produce a leader"
    return 1
  fi
  log "QUORUM_TEST recovery leader=${recovered_leader}"
}
trap 'restore_cluster || true' EXIT

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

leader_port=$(find_leader_port || true)
if [ -z "$leader_port" ]; then
  log "No leader detected before quorum-loss test"
  exit 1
fi
leader_node=$(port_to_node "$leader_port")

log "QUORUM_TEST baseline leader=${leader_port}"

for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$node" = "$leader_node" ]; then
    continue
  fi
  stop_node "$node" "$QUORUM_STOP_MODE"
  record_stopped_node "$node"
  wait_node_down "$node"
  log "QUORUM_TEST stop node=${node} port=$(node_port "$node") mode=${QUORUM_STOP_MODE}"
done

sleep 5

cluster_state=$(fetch_json "${HOST}:${leader_port}/v1/aeron/cluster-state" 2>/dev/null || echo "{}")
health_state=$(fetch_json "${HOST}:${leader_port}/health" 2>/dev/null || echo "{}")
has_quorum=$(json_field "$cluster_state" "quorum.hasQuorum")
reachable=$(json_field "$cluster_state" "reachableCount")
health_cluster=$(json_field "$health_state" "clusterHealthy")

log "QUORUM_TEST survivor port=${leader_port} hasQuorum=${has_quorum:-unset} reachable=${reachable:-unset} clusterHealthy=${health_cluster:-unset}"

if [ "$has_quorum" != "false" ]; then
  log "QUORUM_TEST expected quorum.hasQuorum=false after losing 2 nodes"
  exit 1
fi

submit_result=$(submit_write "${HOST}:${leader_port}" "$QUORUM_TEST_WALLET" "QUORUM_LOSS_$(date +%s)")
submit_code=$(echo "$submit_result" | cut -d'|' -f1)
submit_body=$(echo "$submit_result" | cut -d'|' -f4-)

log "QUORUM_TEST write http=${submit_code} body=${submit_body}"

if [ "$submit_code" = "200" ] || [ "$submit_code" = "202" ]; then
  log "QUORUM_TEST expected write rejection without quorum"
  exit 1
fi

log "SUCCESS quorum loss correctly reported and write refused"

if ! restore_cluster; then
  log "QUORUM_TEST cluster recovery failed"
  exit 1
fi

trap - EXIT
