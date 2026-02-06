#!/bin/bash
set -e

VALIDATOR_URL="${VALIDATOR_URL:-http://localhost:8090}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-10}"
DURATION_SECONDS="${DURATION_SECONDS:-0}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV_LOG="${CSV_LOG:-$LOG_DIR/metrics-${TIMESTAMP}.csv}"

if [ ! -f "$CSV_LOG" ]; then
  echo "timestamp,role,healthy,term,head,replicationLag,pendingCount,mempoolSize,verifiedCount,batchQueueSize,backpressurePendingCount,backpressureActive,backpressureSent,backpressureAcked,backpressurePending,backpressureMax" > "$CSV_LOG"
fi

start_time=$(date +%s)

while true; do
  now=$(date +%s)
  if [ "$DURATION_SECONDS" -gt 0 ] && [ $((now - start_time)) -ge "$DURATION_SECONDS" ]; then
    break
  fi

  ts=$(date '+%Y-%m-%d %H:%M:%S')

  cluster=$(curl -s "${VALIDATOR_URL}/v1/consensus/status" || echo "{}")
  health=$(curl -s "${VALIDATOR_URL}/health" || echo "{}")
  lag=$(curl -s "${VALIDATOR_URL}/v1/aeron/replication-lag" || echo "{}")
  pending=$(curl -s "${VALIDATOR_URL}/v1/proposals/pending/count" || echo "{}")
  queue=$(curl -s "${VALIDATOR_URL}/v1/proposals/queue/stats" || echo "{}")

  role=$(echo "$cluster" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('currentRole',''))
except Exception:
  print('')
PY
)
  healthy=$(echo "$health" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('clusterHealthy',''))
except Exception:
  print('')
PY
)
  term=$(echo "$cluster" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('currentTerm',''))
except Exception:
  print('')
PY
)
  head=$(echo "$cluster" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print((data.get('head','') or '')[:12])
except Exception:
  print('')
PY
)

  lag_val=$(echo "$lag" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('replicationLag',''))
except Exception:
  print('')
PY
)

  pending_count=$(echo "$pending" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('pendingCount',''))
except Exception:
  print('')
PY
)

  mempool_size=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('mempoolSize',''))
except Exception:
  print('')
PY
)
  verified_count=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('verifiedCount',''))
except Exception:
  print('')
PY
)
  batch_queue_size=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('batchQueueSize',''))
except Exception:
  print('')
PY
)
  backpressure_pending=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('backpressurePendingCount',''))
except Exception:
  print('')
PY
)
  backpressure_active=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('backpressureActive',''))
except Exception:
  print('')
PY
)
  backpressure_stats=$(echo "$queue" | python3 - <<'PY'
import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get('backpressureStats',''))
except Exception:
  print('')
PY
)
  backpressure_sent=$(echo "$backpressure_stats" | sed -n 's/.*sent=\([0-9]*\).*/\1/p')
  backpressure_acked=$(echo "$backpressure_stats" | sed -n 's/.*acked=\([0-9]*\).*/\1/p')
  backpressure_pending_raw=$(echo "$backpressure_stats" | sed -n 's/.*pending=\([0-9]*\).*/\1/p')
  backpressure_max=$(echo "$backpressure_stats" | sed -n 's/.*max=\([0-9]*\).*/\1/p')
  backpressure_sent=${backpressure_sent:-}
  backpressure_acked=${backpressure_acked:-}
  backpressure_pending_raw=${backpressure_pending_raw:-}
  backpressure_max=${backpressure_max:-}

  echo "[$ts] role=${role} healthy=${healthy} term=${term} head=${head} lag=${lag_val} pending=${pending_count} mempool=${mempool_size} verified=${verified_count} batch=${batch_queue_size} backpressure=${backpressure_pending}/${backpressure_max} active=${backpressure_active}"
  echo "${ts},${role},${healthy},${term},${head},${lag_val},${pending_count},${mempool_size},${verified_count},${batch_queue_size},${backpressure_pending},${backpressure_active},${backpressure_sent},${backpressure_acked},${backpressure_pending_raw},${backpressure_max}" >> "$CSV_LOG"

  sleep "$INTERVAL_SECONDS"
done
