#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_cluster_test_lib.sh"

CATCHUP_WRITE_COUNT="${CATCHUP_WRITE_COUNT:-8}"
CATCHUP_STOP_MODE="${CATCHUP_STOP_MODE:-crash}"
STOPPED_NODE=""

restore_cluster() {
  if [ -n "$STOPPED_NODE" ] && ! node_up "$STOPPED_NODE"; then
    start_node "$STOPPED_NODE" || true
    wait_node_up "$STOPPED_NODE" || true
  fi
  wait_all_nodes_up 90 || true
}
trap restore_cluster EXIT

leader_port=$(find_leader_port || true)
if [ -z "$leader_port" ]; then
  log "No leader detected before follower catch-up test"
  exit 1
fi
leader_node=$(port_to_node "$leader_port")

follower_node=""
for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$node" = "$leader_node" ]; then
    continue
  fi
  if node_up "$node"; then
    follower_node="$node"
    break
  fi
done

if [ -z "$follower_node" ]; then
  log "No follower available for catch-up test"
  exit 1
fi

log "CATCHUP_TEST leader=${leader_port} follower=$(node_port "$follower_node") writes=${CATCHUP_WRITE_COUNT}"

stop_node "$follower_node" "$CATCHUP_STOP_MODE"
STOPPED_NODE="$follower_node"
wait_node_down "$follower_node"
log "CATCHUP_TEST stop-mode=${CATCHUP_STOP_MODE}"

declare -a STORAGE_PATHS=()
for i in $(seq 1 "$CATCHUP_WRITE_COUNT"); do
  submit_result=$(submit_write "${HOST}:${leader_port}" \
    "0x4444444444444444444444444444444444444444" \
    "FOLLOWER_CATCHUP_${i}_$(date +%s)")
  submit_code=$(echo "$submit_result" | cut -d'|' -f1)
  operation_id=$(echo "$submit_result" | cut -d'|' -f2)
  storage_path=$(echo "$submit_result" | cut -d'|' -f3)
  submit_body=$(echo "$submit_result" | cut -d'|' -f4-)

  if [ "$submit_code" != "200" ] && [ "$submit_code" != "202" ]; then
    log "CATCHUP_TEST write ${i} failed http=${submit_code} body=${submit_body}"
    exit 1
  fi
  if [ -z "$operation_id" ] || [ -z "$storage_path" ]; then
    log "CATCHUP_TEST write ${i} missing operationId or storagePath: ${submit_body}"
    exit 1
  fi
  if ! wait_operation_committed "${HOST}:${leader_port}" "$operation_id"; then
    log "CATCHUP_TEST write ${i} did not commit: ${submit_body}"
    exit 1
  fi

  STORAGE_PATHS+=("$storage_path")
  log "CATCHUP_TEST committed write=${i} path=${storage_path}"
done

start_node "$follower_node"
wait_node_up "$follower_node"
wait_for_role "$follower_node" "FOLLOWER" "$REJOIN_WAIT_SECONDS"

for path in "${STORAGE_PATHS[@]}"; do
  if ! wait_path_visible "$follower_node" "$path"; then
    log "CATCHUP_TEST follower did not catch up path=${path}"
    exit 1
  fi
done

log "SUCCESS follower $(node_port "$follower_node") caught up ${#STORAGE_PATHS[@]} committed writes"
