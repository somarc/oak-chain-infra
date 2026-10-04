#!/bin/bash
set -euo pipefail

HOST="${HOST:-http://localhost}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
VALIDATOR_HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
VALIDATOR_HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
NODES=()
AUTH_TOKEN="${OAK_VALIDATOR_AUTH_TOKEN:-}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/validator-api-smoke-${TIMESTAMP}.log"
# STRICT (default): any endpoint failure or missing required field makes the run exit 1.
# SOFT=1 restores the old report-only behaviour (always exit 0).
SOFT="${SOFT:-0}"
STRICT="${STRICT:-true}"
if [ "$SOFT" = "1" ]; then
  STRICT=false
fi
FAILURES=0

if [ "$CLUSTER_SIZE" = "5" ]; then
  NODE_COUNT=5
else
  NODE_COUNT=3
fi

for node in $(seq 0 $((NODE_COUNT - 1))); do
  NODES+=($((VALIDATOR_HTTP_BASE_PORT + (node * VALIDATOR_HTTP_PORT_STEP))))
done

mkdir -p "$LOG_DIR"

header_args=()
if [ -n "$AUTH_TOKEN" ]; then
  header_args+=( -H "Authorization: Bearer ${AUTH_TOKEN}" )
fi

log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Records one failed check (endpoint error, parse error or missing field).
fail_check() {
  FAILURES=$((FAILURES + 1))
  log "❌ $*"
}

fetch() {
  local url=$1
  local body_file
  body_file=$(mktemp)
  local code
  if [ "${#header_args[@]}" -gt 0 ]; then
    code=$(curl -s --max-time 3 -w "%{http_code}" -o "$body_file" "${header_args[@]}" "$url" || echo "000")
  else
    code=$(curl -s --max-time 3 -w "%{http_code}" -o "$body_file" "$url" || echo "000")
  fi
  local body
  body=$(cat "$body_file")
  rm -f "$body_file"
  echo "${code}::${body}"
}

extract_field() {
  local json=$1
  local field=$2
  python3 -c 'import json,sys
raw=sys.stdin.read()
field=sys.argv[1]
try:
  data=json.loads(raw)
except Exception as e:
  print(f"__PARSE_ERROR__:{e}")
  sys.exit(0)
cur=data
for part in field.split("."):
  if isinstance(cur, dict) and part in cur:
    cur=cur[part]
  else:
    cur=""
    break
print("" if cur is None else cur)
' "$field" <<<"$json"
}

require_field() {
  local json=$1
  local field=$2
  local label=$3
  local value
  value=$(extract_field "$json" "$field")
  if [[ "$value" == "__PARSE_ERROR__"* ]]; then
    fail_check "${label}: json parse error ${value#__PARSE_ERROR__:}"
    log "   ${label}: body snippet: $(echo "$json" | head -c 200)"
    return 0
  fi
  if [ -z "$value" ]; then
    fail_check "${label}: missing field '${field}'"
  else
    log "✅ ${label}: ${field}=${value}"
  fi
}

check_aeron_cluster_state() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/aeron/cluster-state")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "cluster-state HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "role" "cluster-state"
  require_field "$json" "currentLeader" "cluster-state"
  require_field "$json" "memberCount" "cluster-state"
}

check_aeron_raft_metrics() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/aeron/raft-metrics")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "raft-metrics HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "replicationMetrics" "raft-metrics"
  require_field "$json" "commitMetrics" "raft-metrics"
  require_field "$json" "electionMetrics" "raft-metrics"
}

check_aeron_leadership_history() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/aeron/leadership-history")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "leadership-history HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "history" "leadership-history"
}

check_aeron_node_status() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/aeron/node-status")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "node-status HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "role" "node-status"
  require_field "$json" "nodeId" "node-status"
}

check_aeron_replication_lag() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/aeron/replication-lag")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "replication-lag HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  local lag
  lag=$(extract_field "$json" "replicationLag")
  if [ "$lag" = "-1" ]; then
    log "⚠️  replication-lag: leader_log_position_unknown"
  else
    require_field "$json" "replicationLag" "replication-lag"
  fi
}

check_consensus_status() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/consensus/status")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "consensus-status HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "currentRole" "consensus-status"
  require_field "$json" "currentLeader" "consensus-status"
  require_field "$json" "reachableValidators" "consensus-status"
}

check_blockchain_config() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/blockchain/config")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "blockchain-config HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "mode" "blockchain-config"
  require_field "$json" "network" "blockchain-config"
  require_field "$json" "chainId" "blockchain-config"
}

check_proposals_pending() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/proposals/pending/count")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "proposals-pending HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "pendingCount" "proposals-pending"
}

check_queue_stats() {
  local base=$1
  local resp
  resp=$(fetch "${base}/v1/proposals/queue/stats")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "queue-stats HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "mempoolSize" "queue-stats"
  require_field "$json" "verifiedCount" "queue-stats"
  require_field "$json" "batchQueueSize" "queue-stats"
}

check_health() {
  local base=$1
  local resp
  resp=$(fetch "${base}/health")
  local code="${resp%%::*}"
  local json="${resp#*::}"
  if [ "$code" != "200" ]; then
    fail_check "health HTTP ${code}: $(echo "$json" | head -c 200)"
    return 0
  fi
  require_field "$json" "status" "health"
  require_field "$json" "currentRole" "health"
}

log "Validator API smoke test"
log "Nodes: ${NODES[*]}"
log "Host: ${HOST}"

for port in "${NODES[@]}"; do
  base="${HOST}:${port}"
  log "--- Checking ${base} ---"
  check_health "$base" || true
  check_blockchain_config "$base" || true
  check_consensus_status "$base" || true
  check_aeron_cluster_state "$base" || true
  check_aeron_raft_metrics "$base" || true
  check_aeron_leadership_history "$base" || true
  check_aeron_node_status "$base" || true
  check_aeron_replication_lag "$base" || true
  check_proposals_pending "$base" || true
  check_queue_stats "$base" || true
  log "--- Done ${base} ---"
  echo "" | tee -a "$LOG_FILE"
done

if [ "$FAILURES" -eq 0 ]; then
  log "✅ Smoke test complete: all endpoints and required fields present"
  exit 0
fi
if [ "$STRICT" = "true" ]; then
  log "❌ Smoke test failed: ${FAILURES} check(s) failed (SOFT=1 for report-only mode)"
  exit 1
fi
log "⚠️  Smoke test complete with ${FAILURES} failed check(s) (soft mode; exit 0)"
