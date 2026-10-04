#!/bin/bash
set -euo pipefail

OPS_BASE="${OPS_BASE:-http://127.0.0.1:8787}"
# Empty LEADER_BASE = find the leader before every sample from each node's /health currentRole
# (never from the OPS overview, whose leader defaults to node 0).
LEADER_BASE="${LEADER_BASE:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"
DURATION_SECONDS="${DURATION_SECONDS:-1800}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"

mkdir -p "$LOG_DIR"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suite-lib.sh"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
OUT_CSV="${LOG_DIR}/limit-signature-${RUN_TS}.csv"

echo "Capture Limit Signature"
echo "- OPS base: $OPS_BASE"
echo "- Leader base: ${LEADER_BASE:-auto (/health currentRole)}"
echo "- Interval: ${INTERVAL_SECONDS}s"
echo "- Duration: ${DURATION_SECONDS}s"
echo "- Output: $OUT_CSV"

printf "timestamp,queue_pending,backpressure_pending,durability_pending_acks,durability_ack_timeouts,total_verified_count,total_finalized_count,verified_count,processed_count,persistence_pending_changes,backpressure_pending_count,verified_minus_finalized,total_verified_delta,total_finalized_delta\n" > "$OUT_CSV"

end_ts=$(( $(date +%s) + DURATION_SECONDS ))
prev_total_verified=0
prev_total_finalized=0
first=1

while [ "$(date +%s)" -lt "$end_ts" ]; do
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  leader_url="${LEADER_BASE:-$(find_leader_url || true)}"
  overview_json="$(curl -s "$OPS_BASE/ops/v1/overview" || true)"
  queue_json=""
  if [ -n "$leader_url" ]; then
    queue_json="$(curl -s "$leader_url/v1/proposals/queue/stats" || true)"
  fi

  if [ -z "$overview_json" ] || [ -z "$queue_json" ]; then
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  queue_pending="$(printf '%s' "$overview_json" | jq -r '.data.queue.pending // 0' 2>/dev/null || echo 0)"
  backpressure_pending="$(printf '%s' "$overview_json" | jq -r '.data.queue.backpressurePending // 0' 2>/dev/null || echo 0)"
  durability_pending_acks="$(printf '%s' "$overview_json" | jq -r '.data.durability.pendingAcks // 0' 2>/dev/null || echo 0)"
  durability_ack_timeouts="$(printf '%s' "$overview_json" | jq -r '.data.durability.ackTimeouts // 0' 2>/dev/null || echo 0)"

  total_verified_count="$(printf '%s' "$queue_json" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
  total_finalized_count="$(printf '%s' "$queue_json" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
  verified_count="$(printf '%s' "$queue_json" | jq -r '.verifiedCount // 0' 2>/dev/null || echo 0)"
  processed_count="$(printf '%s' "$queue_json" | jq -r '.processedCount // 0' 2>/dev/null || echo 0)"
  persistence_pending_changes="$(printf '%s' "$queue_json" | jq -r '.persistencePendingChanges // 0' 2>/dev/null || echo 0)"
  backpressure_pending_count="$(printf '%s' "$queue_json" | jq -r '.backpressurePendingCount // 0' 2>/dev/null || echo 0)"

  verified_minus_finalized=$((total_verified_count - total_finalized_count))
  if [ "$first" -eq 1 ]; then
    total_verified_delta=0
    total_finalized_delta=0
    first=0
  else
    total_verified_delta=$((total_verified_count - prev_total_verified))
    total_finalized_delta=$((total_finalized_count - prev_total_finalized))
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$ts" \
    "$queue_pending" \
    "$backpressure_pending" \
    "$durability_pending_acks" \
    "$durability_ack_timeouts" \
    "$total_verified_count" \
    "$total_finalized_count" \
    "$verified_count" \
    "$processed_count" \
    "$persistence_pending_changes" \
    "$backpressure_pending_count" \
    "$verified_minus_finalized" \
    "$total_verified_delta" \
    "$total_finalized_delta" >> "$OUT_CSV"

  prev_total_verified="$total_verified_count"
  prev_total_finalized="$total_finalized_count"
  sleep "$INTERVAL_SECONDS"
done

echo "DONE: $OUT_CSV"
