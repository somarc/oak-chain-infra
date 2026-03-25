#!/bin/bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
OUT_DIR="${OUT_DIR:-$LOG_DIR}"
SINCE_LINES="${SINCE_LINES:-2500}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="${OUT_DIR}/validator-triage-${TIMESTAMP}.txt"

NODE_IDS=(0 1 2 3 4)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --log-dir <path>      Validator log directory (default: $LOG_DIR)
  --out <path>          Output report file (default: $OUT_FILE)
  --since-lines <n>     Tail window per validator log (default: $SINCE_LINES)
  --print-only          Print report to stdout, do not write file
  -h, --help            Show this help
USAGE
}

PRINT_ONLY="false"
while (($# > 0)); do
  case "$1" in
    --log-dir)
      shift
      LOG_DIR="${1:?missing path}"
      ;;
    --out)
      shift
      OUT_FILE="${1:?missing file}"
      ;;
    --since-lines)
      shift
      SINCE_LINES="${1:?missing integer}"
      ;;
    --print-only)
      PRINT_ONLY="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$(dirname "$OUT_FILE")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Patterns aligned to recent production-style failure modes.
PATTERN_IPFS='Failed to initialize IPFS BlobStore|Couldn.t connect to IPFS daemon|DataStoreException.*IPFS'
PATTERN_STANDBY='StandbyClientSync|Connection refused: /127\.0\.0\.1:8091|SegmentNotFoundException'
PATTERN_AERON='Failed to connect to Aeron cluster|cluster connect timeout|AeronException|MediaDriver.*crash|Back pressure|concurrent session limit|owned_session_timeout|keepalive_failed|service_loop_error|send failure for|not connected for'
PATTERN_RATE='Rate limit exceeded|429 Too Many Requests'
PATTERN_QUEUE='CRITICAL: Queue depth|backpressure|Queue.*critical|mempool.*full'
PATTERN_FATAL=' FATAL: |Exception|OutOfMemoryError|Shutting down global store server|ERROR '
PATTERN_404_OPS='404 Not Found: GET /v1/ops/snapshots'

count_matches() {
  local pattern="$1"
  local file="$2"
  { rg -n "$pattern" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

emit_section() {
  local title="$1"
  printf "\n=== %s ===\n" "$title"
}

{
  echo "Validator Log Triage"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Log dir: $LOG_DIR"
  echo "Tail window per log: $SINCE_LINES lines"

  emit_section "Per-Node Summary"
  printf "%-10s %-6s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" "node" "exists" "ipfs" "standby" "aeron" "rate" "queue" "fatal" "ops404"

  total_ipfs=0
  total_standby=0
  total_aeron=0
  total_rate=0
  total_queue=0
  total_fatal=0
  total_ops404=0

  for node in "${NODE_IDS[@]}"; do
    src="${LOG_DIR}/validator-${node}.log"
    tail_file="${TMP_DIR}/validator-${node}.tail.log"

    if [ -f "$src" ]; then
      tail -n "$SINCE_LINES" "$src" > "$tail_file"
      exists="yes"

      c_ipfs=$(count_matches "$PATTERN_IPFS" "$tail_file")
      c_standby=$(count_matches "$PATTERN_STANDBY" "$tail_file")
      c_aeron=$(count_matches "$PATTERN_AERON" "$tail_file")
      c_rate=$(count_matches "$PATTERN_RATE" "$tail_file")
      c_queue=$(count_matches "$PATTERN_QUEUE" "$tail_file")
      c_fatal=$(count_matches "$PATTERN_FATAL" "$tail_file")
      c_ops404=$(count_matches "$PATTERN_404_OPS" "$tail_file")

      total_ipfs=$((total_ipfs + c_ipfs))
      total_standby=$((total_standby + c_standby))
      total_aeron=$((total_aeron + c_aeron))
      total_rate=$((total_rate + c_rate))
      total_queue=$((total_queue + c_queue))
      total_fatal=$((total_fatal + c_fatal))
      total_ops404=$((total_ops404 + c_ops404))
    else
      exists="no"
      c_ipfs=0
      c_standby=0
      c_aeron=0
      c_rate=0
      c_queue=0
      c_fatal=0
      c_ops404=0
    fi

    printf "%-10s %-6s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
      "validator-$node" "$exists" "$c_ipfs" "$c_standby" "$c_aeron" "$c_rate" "$c_queue" "$c_fatal" "$c_ops404"
  done

  emit_section "Cluster Totals"
  echo "ipfs_failures=$total_ipfs"
  echo "standby_mismatch=$total_standby"
  echo "aeron_connectivity=$total_aeron"
  echo "rate_limit_events=$total_rate"
  echo "queue_pressure_events=$total_queue"
  echo "fatal_or_exception_events=$total_fatal"
  echo "ops_snapshot_404=$total_ops404"

  emit_section "Quick Verdict"
  if [ "$total_ipfs" -gt 0 ]; then
    echo "- IPFS startup/availability issues detected."
  fi
  if [ "$total_standby" -gt 0 ]; then
    echo "- Legacy standby/bootstrap mismatch signatures detected (8091 loop)."
  fi
  if [ "$total_aeron" -gt 0 ]; then
    echo "- Aeron connectivity/retry issues detected."
  fi
  if [ "$total_rate" -gt 0 ]; then
    echo "- API rate limiting pressure observed (possible downstream stale/429 behavior)."
  fi
  if [ "$total_queue" -gt 0 ]; then
    echo "- Queue/backpressure stress observed."
  fi
  if [ "$total_fatal" -eq 0 ] && [ "$total_ipfs" -eq 0 ] && [ "$total_standby" -eq 0 ] && [ "$total_aeron" -eq 0 ]; then
    echo "- No critical signatures detected in the inspected window."
  fi

  emit_section "Top Error Snippets (last 5 per class)"
  classes=(
    "IPFS|$PATTERN_IPFS"
    "STANDBY|$PATTERN_STANDBY"
    "AERON|$PATTERN_AERON"
    "RATE|$PATTERN_RATE"
    "QUEUE|$PATTERN_QUEUE"
    "FATAL|$PATTERN_FATAL"
  )

  for item in "${classes[@]}"; do
    name="${item%%|*}"
    pattern="${item#*|}"
    echo "-- $name --"
    any=0
    for node in "${NODE_IDS[@]}"; do
      tail_file="${TMP_DIR}/validator-${node}.tail.log"
      if [ -f "$tail_file" ]; then
        matches="$(rg -n "$pattern" "$tail_file" | tail -n 5 || true)"
        if [ -n "$matches" ]; then
          any=1
          while IFS= read -r line; do
            [ -n "$line" ] && echo "validator-$node: $line"
          done <<< "$matches"
        fi
      fi
    done
    [ "$any" -eq 0 ] && echo "(none)"
  done

  emit_section "Suggested Next Checks"
  echo "1) lifecycle/status-cluster.sh"
  echo "2) monitoring/validator-failure-watchdog.sh --status"
  echo "3) curl -s http://127.0.0.1:8787/ops/v1/overview | jq"
  echo "4) curl -s http://127.0.0.1:8090/v1/aeron/cluster-state | jq"
} > "$OUT_FILE"

if [ "$PRINT_ONLY" = "true" ]; then
  cat "$OUT_FILE"
  rm -f "$OUT_FILE"
else
  cat "$OUT_FILE"
  echo
  echo "Report written: $OUT_FILE"
fi
