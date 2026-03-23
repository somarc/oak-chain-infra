#!/bin/bash
set -euo pipefail

OPS_BASE="${OPS_BASE:-http://127.0.0.1:8787}"
HOST_BASE="${HOST_BASE:-http://127.0.0.1}"
LEADER_BASE="${LEADER_BASE:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
DURATION_SECONDS="${DURATION_SECONDS:-1800}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Live evaluator for load tests. Samples OPS + leader queue stats, computes rolling slopes,
and classifies current state and likely bottleneck.

Options:
  --ops-base <url>      OPS base URL (default: $OPS_BASE)
  --host-base <url>     Validator host base without port (default: $HOST_BASE)
  --leader-base <url>   Pin leader URL (skip auto leader detection)
  --interval <sec>      Sampling interval in seconds (default: $INTERVAL_SECONDS)
  --window <sec>        Rolling slope window in seconds (default: $WINDOW_SECONDS)
  --duration <sec>      Total runtime in seconds (default: $DURATION_SECONDS)
  --help                Show help
EOF
}

while (($# > 0)); do
  case "$1" in
    --ops-base) shift; OPS_BASE="${1:-}";;
    --host-base) shift; HOST_BASE="${1:-}";;
    --leader-base) shift; LEADER_BASE="${1:-}";;
    --interval) shift; INTERVAL_SECONDS="${1:-}";;
    --window) shift; WINDOW_SECONDS="${1:-}";;
    --duration) shift; DURATION_SECONDS="${1:-}";;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
CSV="${LOG_DIR}/live-eval-${RUN_TS}.csv"

echo "Live Load Evaluation"
echo "- OPS base: $OPS_BASE"
echo "- Host base: $HOST_BASE"
echo "- Leader base: ${LEADER_BASE:-auto}"
echo "- Interval: ${INTERVAL_SECONDS}s"
echo "- Window: ${WINDOW_SECONDS}s"
echo "- Duration: ${DURATION_SECONDS}s"
echo "- CSV: $CSV"

printf "epoch_s,timestamp,leader_node,leader_port,queue_pending,backpressure_pending,mempool,durability_pending_acks,durability_ack_timeouts,verifier_wait_avg_ms,verifier_wait_max_ms,verifier_error_count,total_verified_count,total_finalized_count,verified_gap,pending_slope_per_min,gap_slope_per_min,durability_slope_per_min,state,bottleneck\n" > "$CSV"

fetch_signal_value() {
  local id="$1"
  local payload="$2"
  printf '%s' "$payload" | jq -r --arg id "$id" '
    (.data.signals // []) | map(select(.id == $id) | .value) | .[0] // 0
  ' 2>/dev/null || echo 0
}

calc_slope_per_min() {
  local field_idx="$1"
  local now_epoch="$2"
  awk -F, -v now="$now_epoch" -v win="$WINDOW_SECONDS" -v idx="$field_idx" '
    NR==1 { next }
    {
      t=$1+0
      if (t >= now-win) {
        if (first_t == 0) { first_t=t; first_v=$idx+0 }
        last_t=t; last_v=$idx+0
      }
    }
    END {
      if (first_t == 0 || last_t == 0 || last_t <= first_t) {
        print "0"
      } else {
        slope=((last_v-first_v)/(last_t-first_t))*60.0
        printf "%.2f", slope
      }
    }
  ' "$CSV"
}

classify_state() {
  local pending_slope="$1"
  local gap_slope="$2"
  local pending="$3"
  local backpressure="$4"
  awk -v ps="$pending_slope" -v gs="$gap_slope" -v p="$pending" -v bp="$backpressure" '
    BEGIN {
      if (ps > 400 || (ps > 150 && gs > 100)) { print "over_limit"; exit }
      if (ps < -120 && gs < -50) { print "recovery"; exit }
      if ((ps > -120 && ps < 120) && (p > 2000 || bp > 2000)) { print "near_limit"; exit }
      print "transitional"
    }'
}

classify_bottleneck() {
  local verifier_avg="$1"
  local verifier_max="$2"
  local verifier_err="$3"
  local pending_slope="$4"
  local gap_slope="$5"
  local backpressure="$6"
  local durability_pending="$7"
  local durability_slope="$8"
  awk -v va="$verifier_avg" -v vm="$verifier_max" -v ve="$verifier_err" \
      -v ps="$pending_slope" -v gs="$gap_slope" -v bp="$backpressure" \
      -v dp="$durability_pending" -v ds="$durability_slope" '
    BEGIN {
      if (ve > 0) { print "verifier_error"; exit }
      if ((vm > 5000 || va > 800) && ps > 100) { print "verifier"; exit }
      if (dp > 500 && ds > 100) { print "persistence"; exit }
      if (bp > 5000 && gs > 100) { print "finalizer_or_sender"; exit }
      print "mixed_or_unknown"
    }'
}

end_ts=$(( $(date +%s) + DURATION_SECONDS ))
echo
echo "time  leader  pending  backpressure  gap(v-f)  verWait(avg/max)  state  bottleneck"
echo "----  ------  -------  ------------  --------  ----------------  -----  ----------"

while [ "$(date +%s)" -lt "$end_ts" ]; do
  epoch_s="$(date +%s)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  overview_json="$(curl -s "$OPS_BASE/ops/v1/overview" || true)"
  signals_json="$(curl -s "$OPS_BASE/ops/v1/signals" || true)"
  if [ -z "$overview_json" ] || [ -z "$signals_json" ]; then
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  leader_node="$(printf '%s' "$overview_json" | jq -r '.data.leader.nodeId // 0' 2>/dev/null || echo 0)"
  leader_port=$((8090 + (leader_node * 2)))
  leader_url="${LEADER_BASE:-$HOST_BASE:$leader_port}"

  queue_json="$(curl -s "$leader_url/v1/proposals/queue/stats" || true)"
  if [ -z "$queue_json" ]; then
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  queue_pending="$(printf '%s' "$overview_json" | jq -r '.data.queue.queuePending // .data.queue.pending // 0' 2>/dev/null || echo 0)"
  backpressure_pending="$(printf '%s' "$overview_json" | jq -r '.data.queue.backpressurePending // 0' 2>/dev/null || echo 0)"
  mempool="$(printf '%s' "$overview_json" | jq -r '.data.queue.mempool // 0' 2>/dev/null || echo 0)"
  durability_pending_acks="$(fetch_signal_value "durability.pending_acks" "$signals_json")"
  durability_ack_timeouts="$(fetch_signal_value "durability.ack_timeouts" "$signals_json")"
  verifier_wait_avg_ms="$(fetch_signal_value "verifier.queue_wait_avg_ms" "$signals_json")"
  verifier_wait_max_ms="$(fetch_signal_value "verifier.queue_wait_max_ms" "$signals_json")"
  verifier_error_count="$(fetch_signal_value "verifier.error_count" "$signals_json")"

  total_verified_count="$(printf '%s' "$queue_json" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
  total_finalized_count="$(printf '%s' "$queue_json" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
  verified_gap=$((total_verified_count - total_finalized_count))

  # slope fields are computed over rolling window using CSV:
  # queue_pending=5, verified_gap=15, durability_pending_acks=8
  pending_slope_per_min="$(calc_slope_per_min 5 "$epoch_s")"
  gap_slope_per_min="$(calc_slope_per_min 15 "$epoch_s")"
  durability_slope_per_min="$(calc_slope_per_min 8 "$epoch_s")"

  state="$(classify_state "$pending_slope_per_min" "$gap_slope_per_min" "$queue_pending" "$backpressure_pending")"
  bottleneck="$(classify_bottleneck "$verifier_wait_avg_ms" "$verifier_wait_max_ms" "$verifier_error_count" "$pending_slope_per_min" "$gap_slope_per_min" "$backpressure_pending" "$durability_pending_acks" "$durability_slope_per_min")"

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$epoch_s" "$timestamp" "$leader_node" "$leader_port" \
    "$queue_pending" "$backpressure_pending" "$mempool" \
    "$durability_pending_acks" "$durability_ack_timeouts" \
    "$verifier_wait_avg_ms" "$verifier_wait_max_ms" "$verifier_error_count" \
    "$total_verified_count" "$total_finalized_count" "$verified_gap" \
    "$pending_slope_per_min" "$gap_slope_per_min" "$durability_slope_per_min" \
    "$state" "$bottleneck" >> "$CSV"

  printf "%s  %s/%s  %s  %s  %s  %s/%s  %s  %s\n" \
    "$(date +%H:%M:%S)" "$leader_node" "$leader_port" \
    "$queue_pending" "$backpressure_pending" "$verified_gap" \
    "$verifier_wait_avg_ms" "$verifier_wait_max_ms" \
    "$state" "$bottleneck"

  sleep "$INTERVAL_SECONDS"
done

echo
echo "DONE: $CSV"
