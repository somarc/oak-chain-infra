#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
mkdir -p "$LOG_DIR"
source "$SCRIPT_DIR/suite-lib.sh"
source "$MOCK_DIR/validators/lifecycle/lib/root-guard.sh"

# Class C fault (SIGSTOP/SIGCONT of one member): refuse the protected live root unless
# OAK_ALLOW_LIVE_ROOT=1, and refuse when the cluster ports belong to another root.
oak_guard_require_target_from_env "unreachable pause draft (class C: SIGSTOP of validator-${REJOIN_NODE_ID:-2})" || exit 1

# Draft scenario:
# 1) start multi-node ingress load
# 2) pause one follower process (SIGSTOP) to simulate "unreachable/unresponsive"
# 3) resume it (SIGCONT) and observe backlog drain behavior
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-900}"
WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
UNREACHABLE_SECONDS="${UNREACHABLE_SECONDS:-90}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
REJOIN_NODE_ID="${REJOIN_NODE_ID:-2}"  # node-id (0/1/2 in 3-node mock)
DISABLE_WATCHDOG="${DISABLE_WATCHDOG:-true}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/06-ultra-ultra-multi-node.sh}"

TS="$(date +%Y%m%d-%H%M%S)"
CSV_OUT="$LOG_DIR/unreachable-pause-drain-${TS}.csv"
RUN_LOG="$LOG_DIR/unreachable-pause-drain-${TS}.log"
CTRL_LOG="$LOG_DIR/unreachable-pause-control-node-${REJOIN_NODE_ID}-${TS}.log"

if [ ! -x "$LOAD_SCRIPT" ]; then
  echo "ERROR: LOAD_SCRIPT is not executable: $LOAD_SCRIPT"
  exit 1
fi

node_port=$((${OAK_VALIDATOR_HTTP_BASE_PORT:-8090} + (REJOIN_NODE_ID * ${OAK_VALIDATOR_HTTP_PORT_STEP:-2})))
node_pid_file="$PID_DIR/validator-${REJOIN_NODE_ID}.pid"

echo "Unreachable Pause/Rejoin Draft"
echo "- Rejoin node-id: $REJOIN_NODE_ID (port $node_port)"
echo "- Warmup: ${WARMUP_SECONDS}s"
echo "- Unreachable window: ${UNREACHABLE_SECONDS}s"
echo "- Duration: ${TEST_DURATION_SECONDS}s"
echo "- CSV: $CSV_OUT"

if [ "$DISABLE_WATCHDOG" = "true" ] && [ -f "$PID_DIR/validator-watchdog.pid" ]; then
  wd_pid="$(cat "$PID_DIR/validator-watchdog.pid" || true)"
  if [ -n "$wd_pid" ]; then
    echo "Stopping watchdog pid=$wd_pid for controlled pause window"
    kill "$wd_pid" 2>/dev/null || true
  fi
fi

NODE_PAUSED=false
NODE_PID=""

cleanup() {
  if [ "${NODE_PAUSED}" = "true" ] && [ -n "${NODE_PID}" ]; then
    kill -CONT "$NODE_PID" 2>/dev/null || true
  fi
  if [ -n "${LOAD_PID:-}" ]; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi
  if [ -n "${SAMPLE_PID:-}" ]; then
    kill "$SAMPLE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

(
  export TEST_DURATION_SECONDS
  "$LOAD_SCRIPT"
) > "$RUN_LOG" 2>&1 &
LOAD_PID=$!
echo "Load started pid=$LOAD_PID"

# Sample leader + target-node queue stats for post-run analysis.
(
  echo "ts_utc,leader_node,leader_port,target_port,target_up,leader_total_verified,leader_total_finalized,leader_backpressure_pending,target_total_verified,target_total_finalized,target_pending,target_batch_queue,target_backpressure_pending"
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Leader from each node's /health currentRole (the OPS overview's leader is unreliable).
    read -r leader_node leader_port <<<"$(leader_node_and_port || true)"

    leader_q="$(curl -s "http://127.0.0.1:${leader_port}/v1/proposals/queue/stats" || true)"
    target_q="$(curl -s "http://127.0.0.1:${node_port}/v1/proposals/queue/stats" || true)"
    target_up="$(curl -s -m 2 "http://127.0.0.1:${node_port}/health" >/dev/null && echo 1 || echo 0)"

    lv="$(echo "$leader_q" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
    lf="$(echo "$leader_q" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
    lb="$(echo "$leader_q" | jq -r '.backpressurePendingCount // 0' 2>/dev/null || echo 0)"
    tv="$(echo "$target_q" | jq -r '.totalVerifiedCount // 0' 2>/dev/null || echo 0)"
    tf="$(echo "$target_q" | jq -r '.totalFinalizedCount // 0' 2>/dev/null || echo 0)"
    tp="$(echo "$target_q" | jq -r '.pendingCount // 0' 2>/dev/null || echo 0)"
    tbq="$(echo "$target_q" | jq -r '.batchQueueSize // 0' 2>/dev/null || echo 0)"
    tb="$(echo "$target_q" | jq -r '.backpressurePendingCount // 0' 2>/dev/null || echo 0)"
    echo "$ts,$leader_node,$leader_port,$node_port,$target_up,$lv,$lf,$lb,$tv,$tf,$tp,$tbq,$tb"
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done
) > "$CSV_OUT" &
SAMPLE_PID=$!
echo "Sampler started pid=$SAMPLE_PID"

sleep "$WARMUP_SECONDS"

if [ -f "$node_pid_file" ]; then
  NODE_PID="$(cat "$node_pid_file" || true)"
fi

if [ -z "$NODE_PID" ]; then
  echo "ERROR: Could not resolve validator-${REJOIN_NODE_ID} PID from $node_pid_file" | tee -a "$CTRL_LOG"
  exit 1
fi
# PID identity (same rule as member.sh): never SIGSTOP a reused pid.
case "$(ps -p "$NODE_PID" -o command= 2>/dev/null || true)" in
  *"$CLUSTER_RUNTIME_ROOT/validator-$REJOIN_NODE_ID"*) ;;
  *)
    echo "ERROR: pid $NODE_PID from $node_pid_file is not validator-${REJOIN_NODE_ID} of $CLUSTER_RUNTIME_ROOT" | tee -a "$CTRL_LOG"
    NODE_PID=""
    exit 1
    ;;
esac

echo "Pausing validator-$REJOIN_NODE_ID pid=$NODE_PID (SIGSTOP)" | tee -a "$CTRL_LOG"
kill -STOP "$NODE_PID"
NODE_PAUSED=true

sleep "$UNREACHABLE_SECONDS"

echo "Resuming validator-$REJOIN_NODE_ID pid=$NODE_PID (SIGCONT)" | tee -a "$CTRL_LOG"
kill -CONT "$NODE_PID"
NODE_PAUSED=false

load_rc=0
wait "$LOAD_PID" || load_rc=$?
kill "$SAMPLE_PID" 2>/dev/null || true
wait "$SAMPLE_PID" 2>/dev/null || true

if [ "$load_rc" -ne 0 ]; then
  echo "ERROR: load generator exited $load_rc (see $RUN_LOG)"
  exit 1
fi
echo "SUCCESS: Unreachable pause/rejoin draft complete"
echo "- run log: $RUN_LOG"
echo "- sampler csv: $CSV_OUT"
echo "- control log: $CTRL_LOG"
echo
echo "Suggested checks:"
echo "1) python3 $SCRIPT_DIR/analyze-queue-samples.py --input \"$CSV_OUT\""
echo "2) rg -n 'CRITICAL: Queue depth|Backpressure timeout|Finalized epoch' $CLUSTER_RUNTIME_ROOT/logs/validator-0.log"
echo "3) rg -n 'Client session|Aeron Cluster service|Restored|Finalized epoch' $CLUSTER_RUNTIME_ROOT/logs/validator-${REJOIN_NODE_ID}.log"
