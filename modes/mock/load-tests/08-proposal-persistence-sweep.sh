#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$MOCK_DIR/validators/lifecycle"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
mkdir -p "$LOG_DIR"

# Sweep defaults tuned for iterative benchmarking (not overnight soak).
TARGET_DURATION_SECONDS="${TARGET_DURATION_SECONDS:-600}"
TARGET_WRITES="${TARGET_WRITES:-33333}"
SLEEP_BETWEEN_CASES_SECONDS="${SLEEP_BETWEEN_CASES_SECONDS:-5}"

# Format: name:persistence_enabled:flush_ms:flush_batch
CASES=(
  "p_on_default:true:250:100"
  "p_on_less_flush:true:1000:500"
  "p_on_more_flush:true:100:50"
  "p_off:false:250:100"
)

TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY_TSV="$LOG_DIR/persistence-sweep-summary-$TS.tsv"
DETAIL_LOG="$LOG_DIR/persistence-sweep-details-$TS.log"

cat > "$SUMMARY_TSV" <<EOF
case	persistence_enabled	flush_ms	flush_batch	report_json	benchmark_rc
EOF

echo "Proposal Persistence Sweep"
echo "- Duration/case: ${TARGET_DURATION_SECONDS}s"
echo "- Target writes/case: ${TARGET_WRITES}"
echo "- Summary: $SUMMARY_TSV"
echo "- Details: $DETAIL_LOG"

make_load_profile() {
  local case_name="$1"
  local out="$2"
  cat > "$out" <<EOF
#!/bin/bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
TEST_NAME="persistence-sweep-${case_name}"
TEST_DURATION_SECONDS=${TARGET_DURATION_SECONDS}
NUM_CLIENTS=12
MIN_WRITES_PER_CLIENT=2000
MAX_WRITES_PER_CLIENT=6000
BINARY_PERCENT=30
VALIDATOR_BINARY_PERCENT=10
SLEEP_MIN_MS=8
SLEEP_MAX_MS=60
REGISTER_CLIENTS=true
source "\$SCRIPT_DIR/run-load-test.sh"
EOF
  chmod +x "$out"
}

for c in "${CASES[@]}"; do
  IFS=':' read -r case_name persist_enabled flush_ms flush_batch <<< "$c"
  echo "===== CASE $case_name =====" | tee -a "$DETAIL_LOG"
  echo "persistence_enabled=$persist_enabled flush_ms=$flush_ms flush_batch=$flush_batch" | tee -a "$DETAIL_LOG"

  (
    cd "$LIFECYCLE_DIR"
    OAK_PROPOSAL_PERSISTENCE_ENABLED="$persist_enabled" \
    OAK_PROPOSAL_PERSISTENCE_FLUSH_MS="$flush_ms" \
    OAK_PROPOSAL_PERSISTENCE_FLUSH_BATCH="$flush_batch" \
      ./start-cluster.sh --fresh --wait-seconds 60
  ) | tee -a "$DETAIL_LOG"

  tmp_profile="/tmp/persistence-sweep-${case_name}-${TS}.sh"
  make_load_profile "$case_name" "$tmp_profile"

  set +e
  benchmark_output="$(
    cd "$SCRIPT_DIR" && \
    TARGET_DURATION_SECONDS="$TARGET_DURATION_SECONDS" TARGET_WRITES="$TARGET_WRITES" \
      ./run-benchmark.sh --load-script "$tmp_profile" --target-writes "$TARGET_WRITES" --target-duration "$TARGET_DURATION_SECONDS" 2>&1
  )"
  rc=$?
  set -e
  echo "$benchmark_output" | tee -a "$DETAIL_LOG"

  report_json="$(echo "$benchmark_output" | awk -F': ' '/Benchmark report JSON:/{print $2}' | tail -n 1)"
  echo -e "${case_name}\t${persist_enabled}\t${flush_ms}\t${flush_batch}\t${report_json}\t${rc}" >> "$SUMMARY_TSV"

  if [ "$SLEEP_BETWEEN_CASES_SECONDS" -gt 0 ]; then
    sleep "$SLEEP_BETWEEN_CASES_SECONDS"
  fi
done

echo
echo "✅ Persistence sweep complete"
echo "- Summary TSV: $SUMMARY_TSV"
echo "- Details log: $DETAIL_LOG"
