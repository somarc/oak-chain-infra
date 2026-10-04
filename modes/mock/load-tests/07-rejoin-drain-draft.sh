#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$MOCK_DIR/validators/lifecycle"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
mkdir -p "$LOG_DIR"
source "$SCRIPT_DIR/suite-lib.sh"
source "$LIFECYCLE_DIR/lib/root-guard.sh"

# Class C fault (SIGKILL + restart of one member): refuse the protected live root unless
# OAK_ALLOW_LIVE_ROOT=1, and refuse when the cluster ports belong to another root.
oak_guard_require_target_from_env "rejoin drain draft (class C: SIGKILL + restart of validator-${REJOIN_NODE_ID:-2})" || exit 1

# member.sh checks PID identity before signalling and keeps the restart's membership in line
# with the launch record. Validator logs stay in the runtime root, not the load LOG_DIR.
member() {
  CLUSTER_RUNTIME_ROOT="$CLUSTER_RUNTIME_ROOT" PID_DIR="$PID_DIR" LOG_DIR="$CLUSTER_RUNTIME_ROOT/logs" \
    "$LIFECYCLE_DIR/member.sh" "$@"
}

# Draft scenario:
# 1) start multi-node ingress load
# 2) kill one follower mid-flight
# 3) restart it and observe backlog drain behavior
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-900}"
WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
DOWN_SECONDS="${DOWN_SECONDS:-90}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
REJOIN_NODE_ID="${REJOIN_NODE_ID:-2}"  # node-id (0/1/2 in 3-node mock)
DISABLE_WATCHDOG="${DISABLE_WATCHDOG:-true}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/06-ultra-ultra-multi-node.sh}"
DOWN_WAIT_TIMEOUT_SECONDS="${DOWN_WAIT_TIMEOUT_SECONDS:-45}"
UP_WAIT_TIMEOUT_SECONDS="${UP_WAIT_TIMEOUT_SECONDS:-120}"

TS="$(date +%Y%m%d-%H%M%S)"
CSV_OUT="$LOG_DIR/rejoin-drain-${TS}.csv"
RUN_LOG="$LOG_DIR/rejoin-drain-${TS}.log"
RESTART_LOG="$LOG_DIR/rejoin-restart-node-${REJOIN_NODE_ID}-${TS}.log"

if [ ! -x "$LOAD_SCRIPT" ]; then
  echo "❌ LOAD_SCRIPT is not executable: $LOAD_SCRIPT"
  exit 1
fi

node_port=$((${OAK_VALIDATOR_HTTP_BASE_PORT:-8090} + (REJOIN_NODE_ID * ${OAK_VALIDATOR_HTTP_PORT_STEP:-2})))

echo "Rejoin Drain Draft"
echo "- Rejoin node-id: $REJOIN_NODE_ID (port $node_port)"
echo "- Warmup: ${WARMUP_SECONDS}s"
echo "- Down: ${DOWN_SECONDS}s"
echo "- Duration: ${TEST_DURATION_SECONDS}s"
echo "- CSV: $CSV_OUT"
echo "- Down wait timeout: ${DOWN_WAIT_TIMEOUT_SECONDS}s"
echo "- Up wait timeout: ${UP_WAIT_TIMEOUT_SECONDS}s"

if [ "$DISABLE_WATCHDOG" = "true" ] && [ -f "$PID_DIR/validator-watchdog.pid" ]; then
  wd_pid="$(cat "$PID_DIR/validator-watchdog.pid" || true)"
  if [ -n "$wd_pid" ]; then
    echo "• Stopping watchdog pid=$wd_pid for controlled rejoin"
    kill "$wd_pid" 2>/dev/null || true
  fi
fi

cleanup() {
  if [ -n "${LOAD_PID:-}" ]; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi
  if [ -n "${SAMPLE_PID:-}" ]; then
    kill "$SAMPLE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

wait_for_node_down() {
  local port="$1"
  local timeout_s="$2"
  local start_s now_s
  start_s="$(date +%s)"
  while true; do
    if ! curl -fsS -m 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    now_s="$(date +%s)"
    if [ $((now_s - start_s)) -ge "$timeout_s" ]; then
      return 1
    fi
    sleep 1
  done
}

wait_for_node_up() {
  local port="$1"
  local timeout_s="$2"
  local start_s now_s
  start_s="$(date +%s)"
  while true; do
    if curl -fsS -m 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    now_s="$(date +%s)"
    if [ $((now_s - start_s)) -ge "$timeout_s" ]; then
      return 1
    fi
    sleep 1
  done
}

(
  export TEST_DURATION_SECONDS
  "$LOAD_SCRIPT"
) > "$RUN_LOG" 2>&1 &
LOAD_PID=$!
echo "• Load started pid=$LOAD_PID"

# Sample leader + target-node queue stats for post-run analysis.
(
  echo "ts_utc,leader_node,leader_port,target_port,leader_total_verified,leader_total_finalized,leader_backpressure_pending,target_total_verified,target_total_finalized,target_pending,target_batch_queue,target_backpressure_pending"
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Leader from each node's /health currentRole (the OPS overview's leader is unreliable).
    read -r leader_node leader_port <<<"$(leader_node_and_port || true)"

    leader_q="$(curl -s "http://127.0.0.1:${leader_port}/v1/proposals/queue/stats" || true)"
    target_q="$(curl -s "http://127.0.0.1:${node_port}/v1/proposals/queue/stats" || true)"

    lv="$(echo "$leader_q" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
    lf="$(echo "$leader_q" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
    lb="$(echo "$leader_q" | jq -r '.backpressurePendingCount // 0' 2>/dev/null || echo 0)"
    tv="$(echo "$target_q" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
    tf="$(echo "$target_q" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
    tp="$(echo "$target_q" | jq -r '.pendingCount // 0' 2>/dev/null || echo 0)"
    tbq="$(echo "$target_q" | jq -r '.batchQueueSize // 0' 2>/dev/null || echo 0)"
    tb="$(echo "$target_q" | jq -r '.backpressurePendingCount // 0' 2>/dev/null || echo 0)"
    echo "$ts,$leader_node,$leader_port,$node_port,$lv,$lf,$lb,$tv,$tf,$tp,$tbq,$tb"
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done
) > "$CSV_OUT" &
SAMPLE_PID=$!
echo "• Sampler started pid=$SAMPLE_PID"

sleep "$WARMUP_SECONDS"

echo "• Killing validator-$REJOIN_NODE_ID via member.sh (SIGKILL)"
if ! member kill "$REJOIN_NODE_ID"; then
  echo "❌ member.sh could not kill validator-$REJOIN_NODE_ID"
  exit 1
fi
if wait_for_node_down "$node_port" "$DOWN_WAIT_TIMEOUT_SECONDS"; then
  echo "• Confirmed validator-$REJOIN_NODE_ID is down on :$node_port"
else
  echo "❌ validator-$REJOIN_NODE_ID did not go down on :$node_port within ${DOWN_WAIT_TIMEOUT_SECONDS}s"
  exit 1
fi

sleep "$DOWN_SECONDS"

echo "• Restarting validator-$REJOIN_NODE_ID via member.sh"
if ! member start "$REJOIN_NODE_ID" > "$RESTART_LOG" 2>&1; then
  cat "$RESTART_LOG"
  echo "❌ member.sh could not restart validator-$REJOIN_NODE_ID"
  exit 1
fi
echo "  restart log: $RESTART_LOG (launcher output: $CLUSTER_RUNTIME_ROOT/logs/start-validator-${REJOIN_NODE_ID}.log)"
if wait_for_node_up "$node_port" "$UP_WAIT_TIMEOUT_SECONDS"; then
  echo "• Confirmed validator-$REJOIN_NODE_ID is back up on :$node_port"
else
  echo "❌ validator-$REJOIN_NODE_ID did not come back on :$node_port within ${UP_WAIT_TIMEOUT_SECONDS}s"
  echo "  restart log: $RESTART_LOG"
  exit 1
fi

load_rc=0
wait "$LOAD_PID" || load_rc=$?
kill "$SAMPLE_PID" 2>/dev/null || true
wait "$SAMPLE_PID" 2>/dev/null || true

if [ "$load_rc" -ne 0 ]; then
  echo "❌ Load generator exited $load_rc (see $RUN_LOG)"
  exit 1
fi
echo "✅ Rejoin drain draft complete"
echo "- run log: $RUN_LOG"
echo "- sampler csv: $CSV_OUT"
echo "- restart log: $RESTART_LOG"
echo
echo "Suggested checks:"
echo "1) rg -n 'Restored .* persisted proposals|QUEUE_TUNING_SOURCE|Epoch finalization check' $CLUSTER_RUNTIME_ROOT/logs/validator-${REJOIN_NODE_ID}.log"
echo "2) python3 $SCRIPT_DIR/analyze-queue-samples.py --input \"$CSV_OUT\""
