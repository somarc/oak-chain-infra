#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
HOST="${HOST:-http://127.0.0.1}"
NODES="${NODES:-8090,8092,8094}"

TARGET_WRITES="${TARGET_WRITES:-100000}"
TARGET_DURATION_SECONDS="${TARGET_DURATION_SECONDS:-1800}"
TAIL_WINDOW_SECONDS="${TAIL_WINDOW_SECONDS:-60}"
MAX_GAP_RATIO="${MAX_GAP_RATIO:-0.25}"
MAX_GAP_ABSOLUTE="${MAX_GAP_ABSOLUTE:-5000}"
MAX_PENDING_SLOPE_PER_S="${MAX_PENDING_SLOPE_PER_S:-2.0}"
MAX_BACKPRESSURE_SLOPE_PER_S="${MAX_BACKPRESSURE_SLOPE_PER_S:-1.0}"
MAX_VERIFIER_WAIT_AVG_MS="${MAX_VERIFIER_WAIT_AVG_MS:-5000}"
MAX_VERIFIER_WAIT_MAX_MS="${MAX_VERIFIER_WAIT_MAX_MS:-60000}"
MAX_429_RATE="${MAX_429_RATE:-0.05}"
RECOVERY_MAX_PENDING_END="${RECOVERY_MAX_PENDING_END:-2000}"
STRICT_UNKNOWN="${STRICT_UNKNOWN:-false}"
LEADER_PARITY_REQUIRED="${LEADER_PARITY_REQUIRED:-true}"
PARITY_MAX_COUNTER_DELTA="${PARITY_MAX_COUNTER_DELTA:-0}"
SAMPLE_NODE="${SAMPLE_NODE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs ADR-068 gate checklist against existing benchmark artifacts.

Options:
  --queue-csv <path>            Queue sampler CSV (default: latest benchmark-queue-*.csv)
  --test-log <path>             Main load test log (default: inferred from benchmark report)
  --client-logs-glob <glob>     Client log glob (default: inferred from test log timestamp)
  --report-json <path>          Output JSON path (default: adr068-report-<ts>.json)
  --host <url>                  Validator host base for leader parity checks (default: http://127.0.0.1)
  --nodes <ports>               Comma-separated ports for leader parity checks (default: 8090,8092,8094)
  --sample-node <port>          Node used for leader-sensitive scoring (default: first node in --nodes)
  --max-counter-delta <n>       Max allowed leader/sample counter delta in parity checks (default: 0)
  --skip-leader-parity          Disable leader parity preflight checks (not recommended)
  --strict-unknown              Fail if a gate metric is missing
  --help                        Show this help
EOF
}

QUEUE_CSV=""
TEST_LOG=""
CLIENT_LOGS_GLOB=""
REPORT_JSON=""

while (($# > 0)); do
  case "$1" in
    --queue-csv) shift; QUEUE_CSV="${1:-}";;
    --test-log) shift; TEST_LOG="${1:-}";;
    --client-logs-glob) shift; CLIENT_LOGS_GLOB="${1:-}";;
    --report-json) shift; REPORT_JSON="${1:-}";;
    --host) shift; HOST="${1:-}";;
    --nodes) shift; NODES="${1:-}";;
    --sample-node) shift; SAMPLE_NODE="${1:-}";;
    --max-counter-delta) shift; PARITY_MAX_COUNTER_DELTA="${1:-}";;
    --skip-leader-parity) LEADER_PARITY_REQUIRED="false";;
    --strict-unknown) STRICT_UNKNOWN="true";;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

if [ -z "$SAMPLE_NODE" ]; then
  SAMPLE_NODE="${NODES%%,*}"
fi

if [ -z "$QUEUE_CSV" ]; then
  QUEUE_CSV="$(ls -t "$LOG_DIR"/benchmark-queue-*.csv 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$QUEUE_CSV" ] || [ ! -f "$QUEUE_CSV" ]; then
  echo "❌ queue CSV not found"
  exit 1
fi

if [ -z "$TEST_LOG" ]; then
  TEST_LOG="$(ls -t "$LOG_DIR"/*.log 2>/dev/null | grep -v "client-" | head -n 1 || true)"
fi
if [ -z "$TEST_LOG" ] || [ ! -f "$TEST_LOG" ]; then
  echo "❌ test log not found"
  exit 1
fi

if [ -z "$CLIENT_LOGS_GLOB" ]; then
  base="$(basename "$TEST_LOG")"
  test_name="${base%-*.log}"
  test_ts="${base#${test_name}-}"
  test_ts="${test_ts%.log}"
  CLIENT_LOGS_GLOB="$LOG_DIR/${test_name}-client-*-${test_ts}.log"
fi

if [ -z "$REPORT_JSON" ]; then
  REPORT_JSON="$LOG_DIR/adr068-report-$(date +%Y%m%d-%H%M%S).json"
fi

if [ "$LEADER_PARITY_REQUIRED" = "true" ]; then
  PARITY_LOG="$LOG_DIR/adr068-leader-parity-$(date +%Y%m%d-%H%M%S).env"
  echo "- leader parity: required"
  set +e
  python3 "$SCRIPT_DIR/leader-parity-preflight.py" \
    --host "$HOST" \
    --nodes "$NODES" \
    --sample-node "$SAMPLE_NODE" \
    --max-counter-delta "$PARITY_MAX_COUNTER_DELTA" \
    > "$PARITY_LOG"
  parity_rc=$?
  set -e
  cat "$PARITY_LOG"
  if [ "$parity_rc" -ne 0 ]; then
    echo "❌ ADR-068 checklist aborted: leader parity failed"
    exit "$parity_rc"
  fi
else
  echo "- leader parity: skipped"
fi

cmd=(python3 "$SCRIPT_DIR/benchmark-gate.py"
  --queue-csv "$QUEUE_CSV"
  --test-log "$TEST_LOG"
  --client-logs-glob "$CLIENT_LOGS_GLOB"
  --target-writes "$TARGET_WRITES"
  --target-duration-seconds "$TARGET_DURATION_SECONDS"
  --tail-window-seconds "$TAIL_WINDOW_SECONDS"
  --max-gap-ratio "$MAX_GAP_RATIO"
  --max-gap-absolute "$MAX_GAP_ABSOLUTE"
  --max-pending-slope-per-s "$MAX_PENDING_SLOPE_PER_S"
  --max-backpressure-slope-per-s "$MAX_BACKPRESSURE_SLOPE_PER_S"
  --max-verifier-wait-avg-ms "$MAX_VERIFIER_WAIT_AVG_MS"
  --max-verifier-wait-max-ms "$MAX_VERIFIER_WAIT_MAX_MS"
  --max-429-rate "$MAX_429_RATE"
  --recovery-max-pending-end "$RECOVERY_MAX_PENDING_END"
  --json-out "$REPORT_JSON"
)

if [ "$LEADER_PARITY_REQUIRED" = "true" ]; then
  cmd+=(--queue-node "$SAMPLE_NODE")
fi

if [ "$STRICT_UNKNOWN" = "true" ]; then
  cmd+=(--strict-unknown)
fi

echo "ADR-068 Checklist"
echo "- queue CSV: $QUEUE_CSV"
echo "- test log: $TEST_LOG"
echo "- client glob: $CLIENT_LOGS_GLOB"
echo "- report: $REPORT_JSON"
echo "- sample node: $SAMPLE_NODE"

set +e
"${cmd[@]}"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "✅ ADR-068 checklist PASS"
else
  echo "❌ ADR-068 checklist FAIL (exit code $rc)"
fi

exit "$rc"
