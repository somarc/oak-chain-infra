#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_cluster_test_lib.sh"

WARM_FAILOVER_CYCLES="${WARM_FAILOVER_CYCLES:-3}"
FAILOVER_SCRIPT="${FAILOVER_SCRIPT:-$SCRIPT_DIR/aeron-failover-smoke.sh}"
POST_CYCLE_HEALTH_WAIT_SECONDS="${POST_CYCLE_HEALTH_WAIT_SECONDS:-90}"

if ! wait_all_nodes_up "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
  log "Warm failover baseline is not fully UP"
  exit 1
fi

if ! wait_all_nodes_cluster_healthy "$POST_CYCLE_HEALTH_WAIT_SECONDS"; then
  log "Warm failover baseline is not cluster healthy"
  exit 1
fi

for cycle in $(seq 1 "$WARM_FAILOVER_CYCLES"); do
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
done

if rg -n "concurrent session limit" "$LOG_DIR"/validator-*.log >/dev/null 2>&1; then
  log "WARM_FAILOVER detected concurrent session limit in validator logs"
  rg -n "concurrent session limit" "$LOG_DIR"/validator-*.log || true
  exit 1
fi

log "SUCCESS warm_failover_cycles=${WARM_FAILOVER_CYCLES}"
