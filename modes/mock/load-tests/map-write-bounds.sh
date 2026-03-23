#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
HOST="${HOST:-http://127.0.0.1}"
NODES="${NODES:-8090,8092,8094}"
VALIDATOR_URL="${VALIDATOR_URL:-http://127.0.0.1:8090}"

CLIENT_STEPS_CSV="${CLIENT_STEPS_CSV:-12,16,20,24,28,30}"
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-600}"
TARGET_RPS="${TARGET_RPS:-55.5556}" # 100k / 1800s baseline
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
SAMPLER_BUFFER_SECONDS="${SAMPLER_BUFFER_SECONDS:-30}"

MIN_WRITES_PER_CLIENT="${MIN_WRITES_PER_CLIENT:-20000}"
MAX_WRITES_PER_CLIENT="${MAX_WRITES_PER_CLIENT:-200000}"
BINARY_PERCENT="${BINARY_PERCENT:-40}"
VALIDATOR_BINARY_PERCENT="${VALIDATOR_BINARY_PERCENT:-10}"
SLEEP_MIN_MS="${SLEEP_MIN_MS:-5}"
SLEEP_MAX_MS="${SLEEP_MAX_MS:-50}"
REGISTER_CLIENTS="${REGISTER_CLIENTS:-true}"

MAX_429_BODY_SAMPLES_PER_CLIENT="${MAX_429_BODY_SAMPLES_PER_CLIENT:-1}"
MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT="${MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT:-10}"
FAIL_SUMMARY_INTERVAL="${FAIL_SUMMARY_INTERVAL:-500}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs stepped benchmark probes and produces a bound map summary.

Options:
  --clients <csv>             Client steps CSV (default: $CLIENT_STEPS_CSV)
  --duration <seconds>        Probe duration per step (default: $TEST_DURATION_SECONDS)
  --target-rps <float>        Gate target finalized rps (default: $TARGET_RPS)
  --host <url>                Validator host (default: $HOST)
  --nodes <ports>             Sampler node ports CSV (default: $NODES)
  --sample-interval <sec>     Queue sample interval (default: $SAMPLE_INTERVAL_SECONDS)
  --sampler-buffer <sec>      Queue sampler tail buffer (default: $SAMPLER_BUFFER_SECONDS)
  --help                      Show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    --clients) shift; CLIENT_STEPS_CSV="${1:-}";;
    --duration) shift; TEST_DURATION_SECONDS="${1:-}";;
    --target-rps) shift; TARGET_RPS="${1:-}";;
    --host) shift; HOST="${1:-}";;
    --nodes) shift; NODES="${1:-}";;
    --sample-interval) shift; SAMPLE_INTERVAL_SECONDS="${1:-}";;
    --sampler-buffer) shift; SAMPLER_BUFFER_SECONDS="${1:-}";;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="${LOG_DIR}/write-bounds-summary-${RUN_ID}.tsv"
DETAILS_FILE="${LOG_DIR}/write-bounds-details-${RUN_ID}.log"

printf "step\tclients\tresult\tfinalized_rps\tverify_rps\tingest_rps\tdrift_end\tdrift_max\tfinalized_delta\thttp429\ttotal_fail\treport\n" > "$SUMMARY_FILE"

TARGET_WRITES="$(python3 - <<PY
target_rps = float("${TARGET_RPS}")
duration = int("${TEST_DURATION_SECONDS}")
print(int(round(target_rps * duration)))
PY
)"

echo "Write Bounds Sweep"
echo "- Run ID: $RUN_ID"
echo "- Clients: $CLIENT_STEPS_CSV"
echo "- Duration/step: ${TEST_DURATION_SECONDS}s"
echo "- Gate target: ${TARGET_RPS} finalized rps (~${TARGET_WRITES} writes/${TEST_DURATION_SECONDS}s)"
echo "- Validator URL: ${VALIDATOR_URL}"
echo "- Summary: $SUMMARY_FILE"
echo "- Details: $DETAILS_FILE"

IFS=',' read -r -a CLIENT_STEPS <<< "$CLIENT_STEPS_CSV"

step=0
for clients in "${CLIENT_STEPS[@]}"; do
  step=$((step + 1))
  test_name="bound-probe-c${clients}-${RUN_ID}"
  profile_path="/tmp/${test_name}.sh"

  cat > "$profile_path" <<EOF
#!/bin/bash
set -e
SCRIPT_DIR="${SCRIPT_DIR}"
TEST_NAME="${test_name}"
TEST_DURATION_SECONDS=${TEST_DURATION_SECONDS}
VALIDATOR_URL="${VALIDATOR_URL}"
NUM_CLIENTS=${clients}
MIN_WRITES_PER_CLIENT=${MIN_WRITES_PER_CLIENT}
MAX_WRITES_PER_CLIENT=${MAX_WRITES_PER_CLIENT}
BINARY_PERCENT=${BINARY_PERCENT}
VALIDATOR_BINARY_PERCENT=${VALIDATOR_BINARY_PERCENT}
SLEEP_MIN_MS=${SLEEP_MIN_MS}
SLEEP_MAX_MS=${SLEEP_MAX_MS}
REGISTER_CLIENTS=${REGISTER_CLIENTS}
MAX_429_BODY_SAMPLES_PER_CLIENT=${MAX_429_BODY_SAMPLES_PER_CLIENT}
MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT=${MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT}
FAIL_SUMMARY_INTERVAL=${FAIL_SUMMARY_INTERVAL}
source "\$SCRIPT_DIR/run-load-test.sh"
EOF
  chmod +x "$profile_path"

  echo "[step $step] clients=$clients test=$test_name" | tee -a "$DETAILS_FILE"

  rc=0
  "$SCRIPT_DIR/run-benchmark.sh" \
    --load-script "$profile_path" \
    --host "$HOST" \
    --nodes "$NODES" \
    --sample-interval "$SAMPLE_INTERVAL_SECONDS" \
    --sampler-buffer "$SAMPLER_BUFFER_SECONDS" \
    --target-writes "$TARGET_WRITES" \
    --target-duration "$TEST_DURATION_SECONDS" \
    >> "$DETAILS_FILE" 2>&1 || rc=$?

  report_path="$(ls -t "$LOG_DIR"/benchmark-report-"${test_name}"-*.json 2>/dev/null | head -n 1 || true)"
  if [ -z "$report_path" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$step" "$clients" "ERROR" "NA" "NA" "NA" "NA" "NA" "NA" "NA" "NA" "missing-report" >> "$SUMMARY_FILE"
    rm -f "$profile_path"
    continue
  fi

  metrics="$(python3 - <<PY
import json
path = "${report_path}"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
q = data.get("queue_metrics", {})
h = data.get("client_http_errors", {})
vals = [
    "PASS" if data.get("passed") else ("FAIL" if ${rc} == 2 else "ERROR"),
    q.get("finalized_rps"),
    q.get("verify_rps"),
    q.get("ingest_rps"),
    q.get("drift_end"),
    q.get("drift_max"),
    q.get("finalized_delta", q.get("processed_delta")),
    h.get("429", 0),
    h.get("total_fail", 0),
]
print("\t".join(str(v) for v in vals))
PY
)"

  printf "%s\t%s\t%s\t%s\n" "$step" "$clients" "$metrics" "$report_path" >> "$SUMMARY_FILE"
  rm -f "$profile_path"
done

echo "✅ Sweep complete"
echo "Summary: $SUMMARY_FILE"
echo "Details: $DETAILS_FILE"
