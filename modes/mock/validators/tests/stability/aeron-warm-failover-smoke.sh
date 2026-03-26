#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TESTS_DIR/lib/_cluster_test_lib.sh"

WARM_FAILOVER_CYCLES="${WARM_FAILOVER_CYCLES:-3}"
FAILOVER_SCRIPT="${FAILOVER_SCRIPT:-$SCRIPT_DIR/aeron-failover-smoke.sh}"
POST_CYCLE_HEALTH_WAIT_SECONDS="${POST_CYCLE_HEALTH_WAIT_SECONDS:-90}"
WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS="${WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS:-}"

if [ -z "$WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS" ]; then
  if [ "${OAK_CLUSTER_SESSION_TIMEOUT_MINUTES:-0}" -gt 0 ] 2>/dev/null; then
    WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS=$((OAK_CLUSTER_SESSION_TIMEOUT_MINUTES * 60 + 5))
  else
    WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS=0
  fi
fi

if ! wait_all_nodes_up "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
  log "Warm failover baseline is not fully UP"
  exit 1
fi

if ! wait_all_nodes_cluster_healthy "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
  log "Warm failover baseline is not cluster healthy"
  exit 1
fi

log_cluster_snapshot() {
  local label="$1"
  local node
  for node in $(seq 0 $((OAK_CLUSTER_SIZE - 1))); do
    local port
    local code
    local body
    local status
    local role
    local healthy
    port="$(node_port "$node")"
    code="$(http_code "$(node_base "$node")${LOCAL_HEALTH_PATH}" || echo "000")"
    body="$(fetch_json "$(node_base "$node")/health" 2>/dev/null || echo "{}")"
    status="$(json_field "$body" "status")"
    role="$(json_field "$body" "currentRole")"
    healthy="$(json_field "$body" "clusterHealthy")"
    log "${label} node=${node} port=${port} http=${code:-000} status=${status:-unknown} role=${role:-unknown} clusterHealthy=${healthy:-unknown}"
  done
}

for cycle in $(seq 1 "$WARM_FAILOVER_CYCLES"); do
  if ! wait_all_nodes_up "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
    log "WARM_FAILOVER cycle=${cycle} baseline did not have all nodes UP"
    log_cluster_snapshot "WARM_FAILOVER baseline"
    exit 1
  fi

  if ! wait_all_nodes_cluster_healthy "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
    log "WARM_FAILOVER cycle=${cycle} baseline did not have cluster healthy"
    log_cluster_snapshot "WARM_FAILOVER baseline"
    exit 1
  fi

  log "WARM_FAILOVER cycle=${cycle}/${WARM_FAILOVER_CYCLES} starting"
  "$FAILOVER_SCRIPT"

  if ! wait_all_nodes_up "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
    log "WARM_FAILOVER cycle=${cycle} did not return all nodes to UP"
    exit 1
  fi

  if ! wait_all_nodes_cluster_healthy "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
    log "WARM_FAILOVER cycle=${cycle} did not return cluster to healthy"
    exit 1
  fi

  log "WARM_FAILOVER cycle=${cycle} healthy"

  if [ "$cycle" -lt "$WARM_FAILOVER_CYCLES" ] && [ "$WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS" -gt 0 ] 2>/dev/null; then
    log "WARM_FAILOVER cycle=${cycle} ingress-drain sleep=${WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS}s"
    sleep "$WARM_FAILOVER_INTER_CYCLE_DRAIN_SECONDS"

    if ! wait_all_nodes_up "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
      log "WARM_FAILOVER cycle=${cycle} drain window lost node availability; deferring hard failure to next cycle baseline"
      log_cluster_snapshot "WARM_FAILOVER drain"
    fi

    if ! wait_all_nodes_cluster_healthy "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
      log "WARM_FAILOVER cycle=${cycle} drain window lost cluster health; deferring hard failure to next cycle baseline"
      log_cluster_snapshot "WARM_FAILOVER drain"
    fi
  fi
done

if rg -n "concurrent session limit" "$LOG_DIR"/validator-*.log >/dev/null 2>&1; then
  log "WARM_FAILOVER detected concurrent session limit in validator logs"
  rg -n "concurrent session limit" "$LOG_DIR"/validator-*.log || true
  exit 1
fi

log "SUCCESS warm_failover_cycles=${WARM_FAILOVER_CYCLES}"
