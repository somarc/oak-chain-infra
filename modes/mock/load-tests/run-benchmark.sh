#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
HOST="${HOST:-http://127.0.0.1}"
NODES="${NODES:-8090,8092,8094}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/03-heavy-30min-priority.sh}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
SAMPLER_BUFFER_SECONDS="${SAMPLER_BUFFER_SECONDS:-30}"
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
STRICT_UNKNOWN_GATES="${STRICT_UNKNOWN_GATES:-false}"
LEADER_PARITY_REQUIRED="${LEADER_PARITY_REQUIRED:-true}"
PARITY_MAX_COUNTER_DELTA="${PARITY_MAX_COUNTER_DELTA:-0}"
SAMPLE_NODE="${SAMPLE_NODE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --load-script <path>         Load script to run (default: 03-heavy-30min-priority.sh)
  --host <url>                 Validator host base (default: http://127.0.0.1)
  --nodes <ports>              Comma-separated node ports (default: 8090,8092,8094)
  --sample-interval <seconds>  Queue sampler interval (default: 5)
  --sampler-buffer <seconds>   Extra sampler tail duration (default: 30)
  --target-writes <count>      Benchmark target writes (default: 100000)
  --target-duration <seconds>  Benchmark target duration (default: 1800)
  --sample-node <port>         Node used for leader-sensitive scoring (default: first node in --nodes)
  --max-counter-delta <n>      Max allowed leader/sample counter delta in parity checks (default: 0)
  --skip-leader-parity         Disable leader parity preflight checks (not recommended)
  --strict-unknown-gates       Fail if any ADR-068 gate metric is missing
  --help                       Show this help
EOF
}

resolve_name_setting() {
  local raw="$1"
  local env_name="$2"
  local env_val="${!env_name:-}"
  if [ -z "$raw" ]; then
    echo ""
    return
  fi
  if [[ "$raw" =~ ^\$\{[^:}]+:-([^}]+)\}$ ]]; then
    if [ -n "$env_val" ]; then
      echo "$env_val"
    else
      echo "${BASH_REMATCH[1]}"
    fi
    return
  fi
  echo "$raw"
}

while (($# > 0)); do
  case "$1" in
    --load-script) shift; LOAD_SCRIPT="${1:-}";;
    --host) shift; HOST="${1:-}";;
    --nodes) shift; NODES="${1:-}";;
    --sample-interval) shift; SAMPLE_INTERVAL_SECONDS="${1:-}";;
    --sampler-buffer) shift; SAMPLER_BUFFER_SECONDS="${1:-}";;
    --target-writes) shift; TARGET_WRITES="${1:-}";;
    --target-duration) shift; TARGET_DURATION_SECONDS="${1:-}";;
    --sample-node) shift; SAMPLE_NODE="${1:-}";;
    --max-counter-delta) shift; PARITY_MAX_COUNTER_DELTA="${1:-}";;
    --skip-leader-parity) LEADER_PARITY_REQUIRED="false";;
    --strict-unknown-gates) STRICT_UNKNOWN_GATES="true";;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

if [ ! -x "$LOAD_SCRIPT" ]; then
  echo "❌ Load script not executable: $LOAD_SCRIPT"
  exit 1
fi

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

if [ -z "$SAMPLE_NODE" ]; then
  SAMPLE_NODE="${NODES%%,*}"
fi

TEST_NAME_RAW="$(awk -F= '/^TEST_NAME=/{gsub(/"/,"",$2); print $2; exit}' "$LOAD_SCRIPT")"
TEST_NAME_PREFIX_RAW="$(awk -F= '/^TEST_NAME_PREFIX=/{gsub(/"/,"",$2); print $2; exit}' "$LOAD_SCRIPT")"
INFERRED_TEST_NAME="$(resolve_name_setting "$TEST_NAME_RAW" TEST_NAME)"
INFERRED_TEST_NAME_PREFIX="$(resolve_name_setting "$TEST_NAME_PREFIX_RAW" TEST_NAME_PREFIX)"
if [ -z "$INFERRED_TEST_NAME" ] && [ -z "$INFERRED_TEST_NAME_PREFIX" ]; then
  echo "❌ Could not infer TEST_NAME or TEST_NAME_PREFIX from $LOAD_SCRIPT"
  exit 1
fi

if [ -n "$INFERRED_TEST_NAME" ]; then
  BENCH_LABEL="$INFERRED_TEST_NAME"
  LOAD_MODE="single-node"
else
  BENCH_LABEL="$INFERRED_TEST_NAME_PREFIX"
  LOAD_MODE="multi-node"
fi

# Profiles declare TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-N}" so env overrides apply.
TEST_DURATION_FROM_SCRIPT="$(resolve_name_setting "$(awk -F= '/^TEST_DURATION_SECONDS=/{gsub(/"/,"",$2); print $2; exit}' "$LOAD_SCRIPT")" TEST_DURATION_SECONDS)"
if [[ "$TEST_DURATION_FROM_SCRIPT" =~ ^[0-9]+$ ]]; then
  TARGET_DURATION_SECONDS="$TEST_DURATION_FROM_SCRIPT"
fi
SAMPLER_DURATION_SECONDS=$((TARGET_DURATION_SECONDS + SAMPLER_BUFFER_SECONDS))

QUEUE_CSV="${LOG_DIR}/benchmark-queue-${BENCH_LABEL}-${RUN_TS}.csv"
RUN_LOG="${LOG_DIR}/benchmark-run-${BENCH_LABEL}-${RUN_TS}.log"
REPORT_JSON="${LOG_DIR}/benchmark-report-${BENCH_LABEL}-${RUN_TS}.json"
PARITY_PRE_LOG="${LOG_DIR}/benchmark-leader-parity-pre-${BENCH_LABEL}-${RUN_TS}.env"
PARITY_POST_LOG="${LOG_DIR}/benchmark-leader-parity-post-${BENCH_LABEL}-${RUN_TS}.env"
DISCOVERY_MARKER="${LOG_DIR}/.benchmark-marker-${BENCH_LABEL}-${RUN_TS}"
touch "$DISCOVERY_MARKER"

echo "Benchmark Runner"
echo "- Benchmark label: $BENCH_LABEL"
echo "- Load mode: $LOAD_MODE"
echo "- Load script: $LOAD_SCRIPT"
echo "- Host: $HOST"
echo "- Nodes: $NODES"
echo "- Queue CSV: $QUEUE_CSV"
echo "- Run log: $RUN_LOG"
echo "- Target: ${TARGET_WRITES} writes / ${TARGET_DURATION_SECONDS}s"
echo "- Sample node: $SAMPLE_NODE"

run_leader_parity_check() {
  local phase="$1"
  local out_file="$2"
  echo "- Leader parity (${phase})..."
  set +e
  python3 "$SCRIPT_DIR/leader-parity-preflight.py" \
    --host "$HOST" \
    --nodes "$NODES" \
    --sample-node "$SAMPLE_NODE" \
    --max-counter-delta "$PARITY_MAX_COUNTER_DELTA" \
    > "$out_file"
  local rc=$?
  set -e
  cat "$out_file"
  if [ "$rc" -ne 0 ]; then
    echo "❌ Leader parity ${phase} failed; refusing benchmark scoring context."
    return "$rc"
  fi
  return 0
}

if [ "$LEADER_PARITY_REQUIRED" = "true" ]; then
  run_leader_parity_check "pre-run" "$PARITY_PRE_LOG"
fi

cleanup() {
  if [ -n "${SAMPLER_PID:-}" ] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
    kill "$SAMPLER_PID" 2>/dev/null || true
  fi
  rm -f "$DISCOVERY_MARKER"
}
trap cleanup EXIT

python3 "$SCRIPT_DIR/queue-sampler.py" \
  --host "$HOST" \
  --nodes "$NODES" \
  --interval "$SAMPLE_INTERVAL_SECONDS" \
  --duration "$SAMPLER_DURATION_SECONDS" \
  --out "$QUEUE_CSV" &
SAMPLER_PID=$!

echo "- Queue sampler PID: $SAMPLER_PID"

# The load engine now exits non-zero on client failure or an error-budget breach. Keep scoring
# (the report is still useful evidence), then fail the benchmark if either side failed.
set +e
(
  cd "$(dirname "$LOAD_SCRIPT")"
  "./$(basename "$LOAD_SCRIPT")"
) | tee "$RUN_LOG"
LOAD_RC=${PIPESTATUS[0]}
set -e
if [ "$LOAD_RC" -ne 0 ]; then
  echo "❌ Load script exited $LOAD_RC (failed client or error budget breach; see LOAD_SUMMARY above)"
fi

wait "$SAMPLER_PID" 2>/dev/null || true

if [ "$LEADER_PARITY_REQUIRED" = "true" ]; then
  run_leader_parity_check "pre-score" "$PARITY_POST_LOG"
fi

TEST_LOGS=()
CLIENT_LOGS=()
collect_paths() {
  local __resultvar="$1"
  shift
  local collected=()
  while IFS= read -r line; do
    [ -n "$line" ] && collected+=("$line")
  done < <("$@")
  # bash 3.2 + set -u: expanding an empty array is fatal, and that exit reports status 0.
  if [ "${#collected[@]}" -gt 0 ]; then
    eval "$__resultvar=(\"\${collected[@]}\")"
  fi
}

if [ "$LOAD_MODE" = "single-node" ]; then
  collect_paths TEST_LOGS find "$LOG_DIR" -maxdepth 1 -type f -name "${INFERRED_TEST_NAME}-*.log" ! -name "*client-*" -newer "$DISCOVERY_MARKER"
  collect_paths CLIENT_LOGS find "$LOG_DIR" -maxdepth 1 -type f -name "${INFERRED_TEST_NAME}-client-*.log" -newer "$DISCOVERY_MARKER"
else
  collect_paths TEST_LOGS find "$LOG_DIR" -maxdepth 1 -type f -name "${INFERRED_TEST_NAME_PREFIX}-node-*.log" ! -name "*client-*" -newer "$DISCOVERY_MARKER"
  collect_paths CLIENT_LOGS find "$LOG_DIR" -maxdepth 1 -type f -name "${INFERRED_TEST_NAME_PREFIX}-node-*-client-*.log" -newer "$DISCOVERY_MARKER"
fi

if [ "${#TEST_LOGS[@]}" -eq 0 ]; then
  echo "❌ Could not locate main test logs for ${BENCH_LABEL} in $LOG_DIR"
  exit 1
fi
if [ "${#CLIENT_LOGS[@]}" -eq 0 ]; then
  echo "❌ Could not locate client logs for ${BENCH_LABEL} in $LOG_DIR"
  exit 1
fi

echo "- Main test logs: ${#TEST_LOGS[@]}"
echo "- Client logs: ${#CLIENT_LOGS[@]}"

if [ "$LOAD_MODE" = "multi-node" ]; then
  GATE_QUEUE_NODE="ALL"
else
  GATE_QUEUE_NODE="$SAMPLE_NODE"
fi

set +e
gate_args=(
  --queue-csv "$QUEUE_CSV"
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
  --queue-node "$GATE_QUEUE_NODE"
  --json-out "$REPORT_JSON"
)
if [ "$STRICT_UNKNOWN_GATES" = "true" ]; then
  gate_args+=(--strict-unknown)
fi
for test_log in "${TEST_LOGS[@]}"; do
  gate_args+=(--test-log "$test_log")
done
for client_log in "${CLIENT_LOGS[@]}"; do
  gate_args+=(--client-log "$client_log")
done
python3 "$SCRIPT_DIR/benchmark-gate.py" "${gate_args[@]}"
RC=$?
set -e

echo "- Benchmark report JSON: $REPORT_JSON"
if [ "$RC" -eq 0 ]; then
  echo "✅ Benchmark gate PASS"
else
  echo "❌ Benchmark gate FAIL (exit code $RC)"
fi

if [ "$RC" -eq 0 ] && [ "$LOAD_RC" -ne 0 ]; then
  echo "❌ Benchmark FAIL: load script exited $LOAD_RC"
  exit "$LOAD_RC"
fi
exit "$RC"
