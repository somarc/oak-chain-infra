#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

QUORUM_STOP_MODE="${QUORUM_STOP_MODE:-crash}"
QUORUM_ENVELOPE_WALLET="${QUORUM_ENVELOPE_WALLET:-}"
DEFAULT_QUORUM_ENVELOPE_WALLET="0x5555555555555555555555555555555555555555"
QUORUM_SETTLE_SECONDS="${QUORUM_SETTLE_SECONDS:-5}"
STOPPED_NODES=()

restore_cluster() {
  local node
  for node in "${STOPPED_NODES[@]}"; do
    if ! node_up "$node"; then
      start_node "$node" || true
    fi
  done
  if ! wait_all_nodes_up 90; then
    log "QUORUM_ENVELOPE recovery timed out waiting for all nodes up"
    return 1
  fi
  if ! wait_all_nodes_cluster_healthy 120; then
    log "QUORUM_ENVELOPE recovery timed out waiting for clusterHealthy=true on all nodes"
    return 1
  fi
  local recovered_leader
  recovered_leader=$(find_leader_port || true)
  if [ -z "$recovered_leader" ]; then
    log "QUORUM_ENVELOPE recovery did not produce a leader"
    return 1
  fi
  log "QUORUM_ENVELOPE recovery leader=${recovered_leader}"
}
trap 'restore_cluster || true' EXIT

QUORUM_ENVELOPE_WALLET="${QUORUM_ENVELOPE_WALLET:-$(resolve_wallet_for_local_shard "$DEFAULT_QUORUM_ENVELOPE_WALLET" 5)}"
QUORUM_ENVELOPE_WALLET="$(test_wallet_for_address "$QUORUM_ENVELOPE_WALLET")"  # a key we hold (signed writes)

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

expect_cluster_state() {
  local leader_port="$1"
  local expected_quorum="$2"
  local expected_health="$3"
  local label="$4"
  local cluster_state
  local health_state
  local has_quorum
  local cluster_healthy

  cluster_state=$(fetch_json "${HOST}:${leader_port}/v1/aeron/cluster-state" 2>/dev/null || echo "{}")
  health_state=$(fetch_json "${HOST}:${leader_port}/health" 2>/dev/null || echo "{}")
  has_quorum=$(json_field "$cluster_state" "quorum.hasQuorum")
  cluster_healthy=$(json_field "$health_state" "clusterHealthy")

  log "QUORUM_ENVELOPE ${label}: leader=${leader_port} hasQuorum=${has_quorum:-unset} clusterHealthy=${cluster_healthy:-unset}"

  [ "$has_quorum" = "$expected_quorum" ] || {
    log "QUORUM_ENVELOPE ${label}: expected quorum.hasQuorum=${expected_quorum}"
    return 1
  }
  [ "$cluster_healthy" = "$expected_health" ] || {
    log "QUORUM_ENVELOPE ${label}: expected clusterHealthy=${expected_health}"
    return 1
  }
}

leader_port=$(find_leader_port || true)
if [ -z "$leader_port" ]; then
  log "No leader detected before quorum envelope test"
  exit 1
fi
leader_node=$(port_to_node "$leader_port")
tolerated_losses=$(((OAK_CLUSTER_SIZE - 1) / 2))
loss_threshold=$((tolerated_losses + 1))

log "QUORUM_ENVELOPE baseline leader=${leader_port} cluster-size=${OAK_CLUSTER_SIZE} tolerated-losses=${tolerated_losses} wallet=${QUORUM_ENVELOPE_WALLET}"

FOLLOWER_NODES=()
for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
  if [ "$node" = "$leader_node" ]; then
    continue
  fi
  FOLLOWER_NODES+=("$node")
done

if [ "${#FOLLOWER_NODES[@]}" -lt "$loss_threshold" ]; then
  log "Not enough followers to exercise quorum envelope"
  exit 1
fi

for idx in $(seq 1 "$loss_threshold"); do
  node="${FOLLOWER_NODES[$((idx - 1))]}"
  stop_node "$node" "$QUORUM_STOP_MODE"
  record_stopped_node "$node"
  wait_node_down "$node"
  log "QUORUM_ENVELOPE stop node=${node} port=$(node_port "$node") mode=${QUORUM_STOP_MODE} step=${idx}/${loss_threshold}"
  sleep "$QUORUM_SETTLE_SECONDS"

  if [ "$idx" -le "$tolerated_losses" ]; then
    expect_cluster_state "$leader_port" "true" "true" "step=${idx} tolerated-loss" || exit 1
    submit_result=$(submit_write "${HOST}:${leader_port}" "$QUORUM_ENVELOPE_WALLET" "QUORUM_ENVELOPE_STEP_${idx}_$(date +%s)")
    submit_code=$(echo "$submit_result" | cut -d'|' -f1)
    operation_id=$(echo "$submit_result" | cut -d'|' -f2)
    submit_body=$(echo "$submit_result" | cut -d'|' -f4-)
    if [ "$submit_code" != "200" ] && [ "$submit_code" != "202" ]; then
      log "QUORUM_ENVELOPE tolerated step=${idx} expected write acceptance http=${submit_code} body=${submit_body}"
      exit 1
    fi
    if ! wait_operation_committed "${HOST}:${leader_port}" "$operation_id"; then
      log "QUORUM_ENVELOPE tolerated step=${idx} write did not commit"
      exit 1
    fi
    log "SUCCESS quorum envelope tolerated-loss step=${idx} write committed"
    continue
  fi

  expect_cluster_state "$leader_port" "false" "false" "step=${idx} no-quorum" || exit 1
  submit_result=$(submit_write "${HOST}:${leader_port}" "$QUORUM_ENVELOPE_WALLET" "QUORUM_ENVELOPE_NO_QUORUM_$(date +%s)")
  submit_code=$(echo "$submit_result" | cut -d'|' -f1)
  submit_body=$(echo "$submit_result" | cut -d'|' -f4-)
  log "QUORUM_ENVELOPE no-quorum write http=${submit_code} body=${submit_body}"
  if [ "$submit_code" = "200" ] || [ "$submit_code" = "202" ] || [[ "$submit_body" != *"no_quorum"* ]]; then
    log "QUORUM_ENVELOPE expected no_quorum rejection at step=${idx}"
    exit 1
  fi
done

log "SUCCESS quorum envelope tolerated=${tolerated_losses} loss-threshold=${loss_threshold}"

if ! restore_cluster; then
  log "QUORUM_ENVELOPE recovery failed"
  exit 1
fi
