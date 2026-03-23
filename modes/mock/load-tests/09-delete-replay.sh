#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/suite-lib.sh"

VALIDATOR_URL="${VALIDATOR_URL:-http://localhost:8090}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
INPUT_PATH="${INPUT_PATH:-}"
SLEEP_MS="${SLEEP_MS:-20}"
MAX_DELETES="${MAX_DELETES:-0}"
START_AT="${START_AT:-1}"

usage() {
  cat <<'EOF'
Usage: ./load-tests/09-delete-replay.sh [--input <file-or-dir>] [--max-deletes N] [--sleep-ms N] [--validator-url URL]

Replays delete proposals for previously accepted writes captured by run-load-test.sh with:
  CAPTURE_WRITE_ACCEPTS=true

Accepted input formats:
  - NDJSON file (one JSON object per line)
  - Directory containing client-*.ndjson files

Env vars:
  VALIDATOR_URL  default: http://localhost:8090
  LOG_DIR        default: ~/oak-chain/logs
  INPUT_PATH     optional alternative to --input
  MAX_DELETES    0 = no limit
  START_AT       1-based offset for resume runs
  SLEEP_MS       delay between delete submissions

Examples:
  CAPTURE_WRITE_ACCEPTS=true ./load-tests/05-ultra-30min.sh
  ./load-tests/09-delete-replay.sh
  ./load-tests/09-delete-replay.sh --input ~/oak-chain/logs/ultra-30min-accepted-20260208-120000 --max-deletes 5000
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      INPUT_PATH="${2:-}"
      shift 2
      ;;
    --max-deletes)
      MAX_DELETES="${2:-0}"
      shift 2
      ;;
    --sleep-ms)
      SLEEP_MS="${2:-20}"
      shift 2
      ;;
    --validator-url)
      VALIDATOR_URL="${2:-$VALIDATOR_URL}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required."
  exit 1
fi

if [ -z "$INPUT_PATH" ]; then
  INPUT_PATH="$(ls -1dt "$LOG_DIR"/*-accepted-* 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$INPUT_PATH" ]; then
  echo "ERROR: No capture input found. Run a load test with CAPTURE_WRITE_ACCEPTS=true first."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SOURCE_FILE="$TMP_DIR/source.tsv"
QUEUE_FILE="$TMP_DIR/queue.tsv"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="${LOG_DIR}/delete-replay-${RUN_TS}.log"
FAIL_LOG="${LOG_DIR}/delete-replay-failures-${RUN_TS}.log"

read_input() {
  local input="$1"
  if [ -d "$input" ]; then
    cat "$input"/client-*.ndjson 2>/dev/null || true
    return
  fi
  if [ -f "$input" ]; then
    cat "$input"
    return
  fi
  echo "ERROR: input not found: $input" >&2
  return 1
}

read_input "$INPUT_PATH" \
  | jq -r 'select((.wallet // "") != "" and (.storagePath // "") != "") | [.wallet, .storagePath] | @tsv' \
  | awk '!seen[$0]++' > "$SOURCE_FILE"

TOTAL_AVAILABLE="$(wc -l < "$SOURCE_FILE" | tr -d ' ')"
if [ "$TOTAL_AVAILABLE" -eq 0 ]; then
  echo "ERROR: No wallet/storagePath entries found in $INPUT_PATH"
  exit 1
fi

if [ "$START_AT" -lt 1 ]; then
  START_AT=1
fi

tail -n +"$START_AT" "$SOURCE_FILE" > "$QUEUE_FILE"

if [ "$MAX_DELETES" -gt 0 ]; then
  head -n "$MAX_DELETES" "$QUEUE_FILE" > "$QUEUE_FILE.tmp"
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
fi

TOTAL_TO_RUN="$(wc -l < "$QUEUE_FILE" | tr -d ' ')"

log_line "$RUN_LOG" "Starting delete replay"
log_line "$RUN_LOG" "Validator: ${VALIDATOR_URL}"
log_line "$RUN_LOG" "Input: ${INPUT_PATH}"
log_line "$RUN_LOG" "Available captured writes: ${TOTAL_AVAILABLE}"
log_line "$RUN_LOG" "Replay start offset: ${START_AT}"
log_line "$RUN_LOG" "Replay count: ${TOTAL_TO_RUN}"
log_line "$RUN_LOG" "Sleep between deletes: ${SLEEP_MS}ms"

ok_count=0
fail_count=0
fail_429=0
fail_4xx=0
fail_5xx=0
fail_000=0
fail_other=0

i=0
while IFS=$'\t' read -r wallet storage_path; do
  i=$((i + 1))
  tx_hash="$(random_hex 16)"
  signature="$(random_hex 65)"
  body_file="${TMP_DIR}/resp-${i}.json"

  http_code="$(curl -s -X POST "${VALIDATOR_URL}/v1/propose-delete" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "walletAddress=${wallet}" \
    --data-urlencode "signature=${signature}" \
    --data-urlencode "contentPath=${storage_path}" \
    --data-urlencode "ethereumTxHash=${tx_hash}" \
    -o "$body_file" \
    -w "%{http_code}" 2>/dev/null || echo "000")"

  if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
    ok_count=$((ok_count + 1))
  else
    fail_count=$((fail_count + 1))
    case "$http_code" in
      429) fail_429=$((fail_429 + 1)) ;;
      4??) fail_4xx=$((fail_4xx + 1)) ;;
      5??) fail_5xx=$((fail_5xx + 1)) ;;
      000) fail_000=$((fail_000 + 1)) ;;
      *) fail_other=$((fail_other + 1)) ;;
    esac
    printf 'line=%s http=%s wallet=%s path=%s body=%s\n' \
      "$i" "$http_code" "$wallet" "$storage_path" "$(cat "$body_file" 2>/dev/null)" >> "$FAIL_LOG"
  fi

  if [ $((i % 500)) -eq 0 ]; then
    log_line "$RUN_LOG" "Progress: ${i}/${TOTAL_TO_RUN} ok=${ok_count} fail=${fail_count} http429=${fail_429}"
  fi

  sleep "$(awk "BEGIN {print ${SLEEP_MS}/1000}")"
done < "$QUEUE_FILE"

log_line "$RUN_LOG" "Delete replay complete: total=${TOTAL_TO_RUN} ok=${ok_count} fail=${fail_count} http429=${fail_429} http4xx=${fail_4xx} http5xx=${fail_5xx} http000=${fail_000} other=${fail_other}"
if [ -f "$FAIL_LOG" ]; then
  log_line "$RUN_LOG" "Failures log: ${FAIL_LOG}"
fi

echo "RUN_LOG=${RUN_LOG}"
if [ -f "$FAIL_LOG" ]; then
  echo "FAIL_LOG=${FAIL_LOG}"
fi
