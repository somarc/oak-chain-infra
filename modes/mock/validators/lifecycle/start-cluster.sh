#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/root-guard.sh
source "$SCRIPT_DIR/lib/root-guard.sh"
# shellcheck source=lib/launch-record.sh
source "$SCRIPT_DIR/lib/launch-record.sh"
# shellcheck source=lib/ipfs-gateway.sh
source "$SCRIPT_DIR/lib/ipfs-gateway.sh"
export OAK_BLOCKCHAIN_MODE="${OAK_BLOCKCHAIN_MODE:-mock}"
export OAK_RATE_LIMIT_ENABLED="${OAK_RATE_LIMIT_ENABLED:-false}"
export OAK_CLUSTER_ENV="${OAK_CLUSTER_ENV:-test}"
export OAK_CLUSTER_SESSION_TIMEOUT_SECONDS="${OAK_CLUSTER_SESSION_TIMEOUT_SECONDS:-30}"
VALIDATOR_SCRIPT="$SCRIPT_DIR/../debug/run-validator-node.sh"
PREVENT_SLEEP_SCRIPT="$SCRIPT_DIR/prevent-sleep.sh"
WATCHDOG_SCRIPT="$SCRIPT_DIR/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$SCRIPT_DIR/../monitoring/load-bottleneck-observer.sh"
CLUSTER_NAME="${OAK_CLUSTER_NAME:-single-cluster}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
OAK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
# Preferred location: dedicated edge worker repo. Keep OPS_DASHBOARD_DIR as fallback for compatibility.
OPS_EDGE_WORKER_DIR="${OPS_EDGE_WORKER_DIR:-$OAK_ROOT/oak-chain-edge-worker}"
if [ -n "${OPS_DASHBOARD_DIR:-}" ] && [ "${OPS_DASHBOARD_DIR:-}" != "$OPS_EDGE_WORKER_DIR" ]; then
  OPS_EDGE_WORKER_DIR="$OPS_DASHBOARD_DIR"
fi
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"
OPS_PROXY_LOG_FILE="$LOG_DIR/start-ops-proxy.log"
VALIDATOR_HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
VALIDATOR_HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
VALIDATOR_PROCESS_MATCH="${VALIDATOR_PROCESS_MATCH:-$CLUSTER_RUNTIME_ROOT/validator-}"
ODD_HTTP_BASE_PORT=$((VALIDATOR_HTTP_BASE_PORT + 1))
if [ "${OPS_PROXY_PORT:-}" = "" ]; then
  OPS_PROXY_PORT=8787
fi
if [ "${OPS_PROXY_UPSTREAM:-}" = "" ]; then
  OPS_PROXY_UPSTREAM="http://127.0.0.1:${VALIDATOR_HTTP_BASE_PORT}"
fi
OPS_PROXY_PORT="${OPS_PROXY_PORT:-8787}"
OPS_PROXY_MODE="${OPS_PROXY_MODE:-proxy}"
WAIT_SECONDS="${WAIT_SECONDS:-45}"
MOCK_EPOCH_SECONDS="${OAK_MOCK_EPOCH_DURATION_SECONDS:-300}"
ENABLE_WATCHDOG="${ENABLE_WATCHDOG:-true}"
ENABLE_LOAD_OBSERVER="${ENABLE_LOAD_OBSERVER:-true}"
RESET_CLUSTER_TEST_LOGS="${RESET_CLUSTER_TEST_LOGS:-true}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$CLUSTER_RUNTIME_ROOT/cluster-keystore.properties}"
AERON_CLUSTER_BASE_PORT="${AERON_CLUSTER_BASE_PORT:-9000}"
AERON_GLOBAL_TMP_CLEANUP="${AERON_GLOBAL_TMP_CLEANUP:-false}"
IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"
IPFS_READY_TIMEOUT_SECONDS="${IPFS_READY_TIMEOUT_SECONDS:-30}"
AUTO_START_IPFS="${AUTO_START_IPFS:-true}"
IPFS_DAEMON_LOG_FILE="${IPFS_DAEMON_LOG_FILE:-$LOG_DIR/ipfs-daemon.log}"
IPFS_PID_FILE="${IPFS_PID_FILE:-$PID_DIR/ipfs-daemon.pid}"
# Validators read these (run-validator-node.sh); the default lies outside every validator port
# range (lib/ipfs-gateway.sh). IPFS_GATEWAY_BASE is written into committed content, so every
# member of a cluster must run with the same value.
export IPFS_GATEWAY_BASE="${IPFS_GATEWAY_BASE:-$OAK_IPFS_GATEWAY_DEFAULT_BASE}"
export IPFS_LOCAL_GATEWAY_BASE="${IPFS_LOCAL_GATEWAY_BASE:-$OAK_IPFS_GATEWAY_DEFAULT_BASE}"
NODES=()
HTTP_PORTS=()

mkdir -p "$PID_DIR" "$LOG_DIR"
export OAK_ROOT

resolved_aeron_dir_base() {
  if [ -n "${AERON_DIR_BASE:-}" ]; then
    echo "${AERON_DIR_BASE%/}"
    return
  fi
  if [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
    echo "${AERON_RAMDISK_ROOT%/}/${CLUSTER_NAME}/aeron-media"
  fi
}

validator_reactor_modules() {
  local jr_oak_dir="$1"
  local modules="oak-segment-consensus"
  if [ -f "$jr_oak_dir/oak-segment-agentic/pom.xml" ] && \
     [ -f "$jr_oak_dir/pom.xml" ] && \
     grep -q '<module>oak-segment-agentic</module>' "$jr_oak_dir/pom.xml"; then
    modules="${modules},oak-segment-agentic"
  fi
  echo "$modules"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--fresh] [--build] [--cluster-size 3|5] [--mock-epoch-seconds N] [--reset-cluster-wallet] [--no-caffeinate] [--wait-seconds N]

Options:
  --fresh            Stop validators/proxy, wipe validator runtime state, clean Aeron dirs, then start clean.
  --build            Build oak-segment-consensus and optional validator-side modules present in the current branch.
  --cluster-size N   Aeron member count for mock cluster (3 or 5). Default: $CLUSTER_SIZE.
  --mock-epoch-seconds N  Mock GC epoch duration in seconds (default: $MOCK_EPOCH_SECONDS).
  --reset-cluster-wallet  Delete and regenerate cluster wallet before startup.
  --no-caffeinate    Do not start sleep prevention.
  --wait-seconds N   Readiness wait timeout (default: $WAIT_SECONDS).
  --no-watchdog      Disable validator failure watchdog auto-start.
  --no-load-observer Disable load bottleneck observer auto-start.

Environment:
  RESET_CLUSTER_TEST_LOGS      true|false reset active runtime logs during --fresh preflight (default: $RESET_CLUSTER_TEST_LOGS)
  IPFS_API_HTTP              IPFS API base URL (default: $IPFS_API_HTTP)
  IPFS_READY_TIMEOUT_SECONDS Max seconds to wait for IPFS API readiness (default: $IPFS_READY_TIMEOUT_SECONDS)
  AUTO_START_IPFS            Auto-start IPFS daemon if API is unavailable (default: $AUTO_START_IPFS)
  IPFS_DAEMON_LOG_FILE       Log file for auto-started IPFS daemon (default: $IPFS_DAEMON_LOG_FILE)
  IPFS_PID_FILE              PID file for auto-started IPFS daemon (default: $IPFS_PID_FILE)
  IPFS_GATEWAY_BASE          Gateway base written into content (default: $IPFS_GATEWAY_BASE)
  IPFS_LOCAL_GATEWAY_BASE    Local gateway base; a new ~/.ipfs repo is initialized with its port (default: $IPFS_LOCAL_GATEWAY_BASE)
  CLUSTER_RUNTIME_ROOT       Root directory for stores/logs/pids (default: $CLUSTER_RUNTIME_ROOT)
  OAK_CLUSTER_NAME           Logical cluster label used by status output and 3x2 packs (default: $CLUSTER_NAME)
  OAK_VALIDATOR_HTTP_BASE_PORT Base HTTP port for validator-0 (default: $VALIDATOR_HTTP_BASE_PORT)
  OAK_VALIDATOR_HTTP_PORT_STEP Port step between validators (default: $VALIDATOR_HTTP_PORT_STEP)
  AERON_CLUSTER_BASE_PORT    Base Aeron cluster port block (default: $AERON_CLUSTER_BASE_PORT)
  AERON_DIR_BASE             Base Aeron directory path for per-node MediaDriver dirs (default: $CLUSTER_RUNTIME_ROOT/validator-N/aeron-media)
  AERON_RAMDISK_ROOT         Optional ramdisk root for derived Aeron dirs (example: /Volumes/OakAeron)
  AERON_GLOBAL_TMP_CLEANUP   true|false aggressive global /tmp Aeron cleanup (default: $AERON_GLOBAL_TMP_CLEANUP)
  OAK_PROPOSAL_BATCH_MAX                Queue sender batch max (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_FINALIZATION_CHUNK_SIZE  Finalization chunk size (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_FINALIZATION_CHUNK_DELAY_MS Delay between finalization chunks in ms (default 0)
  OAK_PROPOSAL_PERSISTENCE_ENABLED      true|false queue durability persistence (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_PERSISTENCE_FLUSH_MS     Proposal queue persistence flush interval ms (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_PERSISTENCE_FLUSH_BATCH  Proposal queue persistence flush batch size (OSGi cfg + optional JVM fallback)
  OAK_CONSENSUS_MAX_PENDING_MESSAGES    Backpressure pending cap (OSGi cfg + optional JVM fallback)
  OAK_CONSENSUS_BACKPRESSURE_TIMEOUT_MS Backpressure timeout ms (OSGi cfg + optional JVM fallback)
  OAK_QUEUE_TUNING_SYSTEM_PROP_FALLBACK true|false (default true). Keep JVM -D fallback while validating OSGi pickup.
  OAK_MOCK_EPOCH_DURATION_SECONDS       Mock GC epoch duration in seconds (default: $MOCK_EPOCH_SECONDS).
  OAK_RATE_LIMIT_ENABLED                true|false HTTP rate limiting (default false in mock mode).
EOF
}

FRESH=false
NO_CAFFEINATE=false
RESET_CLUSTER_WALLET=false
BUILD_ON_START=false
while (($# > 0)); do
  case "$1" in
    --fresh) FRESH=true ;;
    --build) BUILD_ON_START=true ;;
    --cluster-size)
      shift
      if [ -z "${1:-}" ] || { [ "$1" != "3" ] && [ "$1" != "5" ]; }; then
        echo "Invalid --cluster-size value (use 3 or 5)"
        usage
        exit 1
      fi
      CLUSTER_SIZE="$1"
      ;;
    --mock-epoch-seconds)
      shift
      if [ -z "${1:-}" ] || ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 0 ]; then
        echo "Invalid --mock-epoch-seconds value (use positive integer seconds)"
        usage
        exit 1
      fi
      MOCK_EPOCH_SECONDS="$1"
      ;;
    --no-caffeinate) NO_CAFFEINATE=true ;;
    --no-watchdog) ENABLE_WATCHDOG=false ;;
    --no-load-observer) ENABLE_LOAD_OBSERVER=false ;;
    --wait-seconds)
      shift
      if [ -z "${1:-}" ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Invalid --wait-seconds value"
        usage
        exit 1
      fi
      WAIT_SECONDS="$1"
      ;;
    --reset-cluster-wallet) RESET_CLUSTER_WALLET=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$CLUSTER_SIZE" != "3" ] && [ "$CLUSTER_SIZE" != "5" ]; then
  echo "Invalid OAK_CLUSTER_SIZE=$CLUSTER_SIZE (expected 3 or 5)"
  exit 1
fi
export OAK_CLUSTER_SIZE="$CLUSTER_SIZE"
export OAK_MOCK_EPOCH_DURATION_SECONDS="$MOCK_EPOCH_SECONDS"

if [ "$CLUSTER_SIZE" = "5" ]; then
  NODES=(0 1 2 3 4)
else
  NODES=(0 1 2)
fi
for node in "${NODES[@]}"; do
  HTTP_PORTS+=($((VALIDATOR_HTTP_BASE_PORT + (node * VALIDATOR_HTTP_PORT_STEP))))
done

# --fresh is risk class D: it signals, wipes and sweeps ports. Refuse it on the protected live
# root (unless OAK_ALLOW_LIVE_ROOT=1) and whenever a cluster port belongs to another root.
if [ "$FRESH" = "true" ] && ! oak_guard_require_fresh_safe "$CLUSTER_RUNTIME_ROOT" "$PID_DIR" \
    "$CLUSTER_SIZE" "$VALIDATOR_HTTP_BASE_PORT" "$VALIDATOR_HTTP_PORT_STEP" "$AERON_CLUSTER_BASE_PORT"; then
  exit 1
fi

find_validator_processes() {
  local pattern
  if [ -n "$VALIDATOR_PROCESS_MATCH" ]; then
    pattern="oak-segment-consensus.*${VALIDATOR_PROCESS_MATCH}"
  else
    pattern="oak-segment-consensus.*${CLUSTER_RUNTIME_ROOT}"
  fi
  pgrep -f "$pattern" 2>/dev/null || true
}

cluster_wallet_address() {
  if [ -f "$CLUSTER_WALLET_FILE" ]; then
    awk -F'=' '/^walletAddress=/{print $2}' "$CLUSTER_WALLET_FILE" | head -n 1
  fi
}

generate_cluster_wallet() {
  local jar_file="$OAK_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
  if [ ! -f "$jar_file" ]; then
    echo "❌ Cannot generate cluster wallet: missing $jar_file"
    return 1
  fi
  if ! command -v javac >/dev/null 2>&1; then
    echo "❌ Cannot generate cluster wallet: javac not found"
    return 1
  fi

  mkdir -p "$(dirname "$CLUSTER_WALLET_FILE")"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  cat > "$tmp_dir/ClusterWalletBootstrap.java" <<'JAVA'
import org.apache.jackrabbit.oak.segment.consensus.security.EthereumWallet;
public class ClusterWalletBootstrap {
  public static void main(String[] args) throws Exception {
    if (args.length != 1) throw new IllegalArgumentException("Expected keystore path");
    EthereumWallet wallet = new EthereumWallet(args[0]);
    System.out.println(wallet.getWalletAddress());
  }
}
JAVA
  javac -cp "$jar_file" "$tmp_dir/ClusterWalletBootstrap.java"
  local wallet_addr
  wallet_addr="$(java -cp "$jar_file:$tmp_dir" ClusterWalletBootstrap "$CLUSTER_WALLET_FILE" | tail -n 1 || true)"
  rm -rf "$tmp_dir"

  if [ -z "$wallet_addr" ] || [ ! -f "$CLUSTER_WALLET_FILE" ]; then
    echo "❌ Failed to generate cluster wallet"
    return 1
  fi
  echo "✅ Cluster wallet generated: $wallet_addr"
  echo "   Keystore: $CLUSTER_WALLET_FILE"
}

ensure_cluster_wallet() {
  if [ "$RESET_CLUSTER_WALLET" = "true" ] && [ -f "$CLUSTER_WALLET_FILE" ]; then
    echo "• Resetting cluster wallet"
    rm -f "$CLUSTER_WALLET_FILE"
  fi

  local wallet_addr
  wallet_addr="$(cluster_wallet_address)"
  if [ -n "$wallet_addr" ]; then
    echo "• Cluster wallet ready: $wallet_addr"
    return 0
  fi

  echo "• No cluster wallet found at $CLUSTER_WALLET_FILE"
  if [ -t 0 ]; then
    printf "  Generate new cluster wallet now? [Y/n] "
    read -r ans || true
    ans="${ans:-Y}"
    case "$ans" in
      y|Y|yes|YES) ;;
      n|N|no|NO)
        echo "  Skipping explicit cluster wallet generation; node wallet fallback will be used."
        return 0
        ;;
      *) ;;
    esac
  fi

  generate_cluster_wallet
}

is_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

is_ipfs_daemon_pid() {
  local pid="$1"
  local cmd
  [ -n "$pid" ] || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"ipfs daemon"* || "$cmd" == *"kubo daemon"* ]]
}

find_ipfs_daemon_pid() {
  pgrep -f "(ipfs|kubo) daemon" 2>/dev/null | head -n 1 || true
}

ipfs_process_running() {
  [ -n "$(find_ipfs_daemon_pid)" ]
}

ipfs_pid_from_file() {
  if [ -f "$IPFS_PID_FILE" ]; then
    tr -d '[:space:]' < "$IPFS_PID_FILE" 2>/dev/null || true
  fi
}

cleanup_stale_ipfs_pid_file() {
  local pid
  pid="$(ipfs_pid_from_file)"
  if [ -n "$pid" ] && ! is_ipfs_daemon_pid "$pid"; then
    rm -f "$IPFS_PID_FILE" 2>/dev/null || true
  fi
}

cleanup_stale_pid_file() {
  local pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return 0
  fi
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if ! is_pid_alive "$pid"; then
    rm -f "$pid_file"
  fi
}

wait_for_pid_file_value() {
  local pid_file="$1"
  local timeout_tenths="${2:-50}"
  local pid=""
  local remaining="$timeout_tenths"

  while [ "$remaining" -gt 0 ]; do
    if [ -f "$pid_file" ]; then
      pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
    else
      pid=""
    fi
    if [ -n "$pid" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    remaining=$((remaining - 1))
    sleep 0.1
  done

  return 1
}

# Only listeners that belong to this runtime root are killed; others are reported and skipped.
kill_ports() {
  oak_guard_kill_owned_ports "$CLUSTER_RUNTIME_ROOT" "$PID_DIR" "$@"
}

launch_detached_process() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >>"$log_file" 2>&1 &
    echo $! > "$pid_file"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$pid_file" "$log_file" "$@" <<'PY'
import os
import sys

pid_file = sys.argv[1]
log_file = sys.argv[2]
cmd = sys.argv[3:]

pid = os.fork()
if pid > 0:
    os._exit(0)

os.setsid()

pid = os.fork()
if pid > 0:
    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{pid}\n")
    os._exit(0)

with open(log_file, "ab", buffering=0) as log:
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
os.execvp(cmd[0], cmd)
PY
    if ! wait_for_pid_file_value "$pid_file" >/dev/null; then
      return 1
    fi
    return 0
  fi

  echo "⚠️  setsid/python3 unavailable; falling back to nohup for detached launch"
  nohup "$@" >>"$log_file" 2>&1 &
  echo $! > "$pid_file"
}

cleanup_aeron_runtime() {
  local username
  local custom_aeron_dir_base
  local cleaned_count=0
  username="$(whoami)"
  custom_aeron_dir_base="$(resolved_aeron_dir_base)"
  echo "• Cleaning Aeron runtime directories"
  for node in "${NODES[@]}"; do
    local path
    path="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-cluster-node-$node"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
    fi
    path="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-cluster-node-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
    path="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-media-driver-$node"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
    path="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-media-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
    if [ -n "$custom_aeron_dir_base" ]; then
      path="${custom_aeron_dir_base}-${node}-driver"
      if [ -d "$path" ]; then
        echo "  - Removing: $path"
        rm -rf "$path" 2>/dev/null || true
      fi
      path="${custom_aeron_dir_base}-${node}"
      if [ -d "$path" ]; then
        echo "  - Removing: $path"
        rm -rf "$path" 2>/dev/null || true
      fi
    fi
    path="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-$username-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
  done

  if [ "$AERON_GLOBAL_TMP_CLEANUP" = "true" ]; then
    echo "  - Aggressive global Aeron tmp cleanup enabled"
    for node in "${NODES[@]}"; do
      for path in \
        "/tmp/aeron-${username}-${node}-driver" \
        "/tmp/aeron-${username}-driver-${node}" \
        "/tmp/aeron-cluster-node-${node}"; do
        if [ -d "$path" ]; then
          echo "  - Removing: $path"
          rm -rf "$path" 2>/dev/null || true
        fi
      done
    done

    if [ -d "/var/folders" ]; then
      while IFS= read -r path; do
        if [ -d "$path" ]; then
          echo "  - Removing: $path"
          rm -rf "$path" 2>/dev/null || true
        fi
      done < <(find /var/folders -type d \( \
        -name "aeron-${username}-*-driver" -o \
        -name "aeron-cluster-node-*" \
      \) 2>/dev/null || true)
    fi

    echo "  - Checking for orphaned Aeron directories..."
    while IFS= read -r path; do
      if [ -d "$path" ]; then
        echo "  - Removing orphaned: $path"
        rm -rf "$path" 2>/dev/null || true
      fi
    done < <(find /tmp -maxdepth 1 -type d -name "aeron-*" 2>/dev/null || true)
  fi

  if [ "$cleaned_count" -gt 0 ]; then
    echo "• Cleaned $cleaned_count Aeron cluster directory(ies)"
  fi
}

cleanup_validator_runtime_state() {
  local cleaned_count=0
  echo "• Cleaning validator runtime state"

  for node in "${NODES[@]}"; do
    local store_dir="$CLUSTER_RUNTIME_ROOT/validator-$node"
    local entry
    local removed_any=false

    [ -d "$store_dir" ] || continue

    shopt -s nullglob dotglob
    for entry in "$store_dir"/*; do
      case "$(basename "$entry")" in
        validator-keystore.properties)
          continue
          ;;
      esac

      echo "  - Removing: $entry"
      rm -rf "$entry" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
      removed_any=true
    done
    shopt -u nullglob dotglob

    if [ "$removed_any" = false ]; then
      echo "  - No runtime state under: $store_dir"
    fi
  done

  if [ "$cleaned_count" -gt 0 ]; then
    echo "• Cleaned $cleaned_count validator runtime directory(ies)"
  else
    echo "• No validator runtime state to clean"
  fi
}

reset_active_runtime_logs() {
  [ "$RESET_CLUSTER_TEST_LOGS" = "true" ] || return 0

  echo "• Resetting active runtime logs"

  local paths=(
    "$OPS_PROXY_LOG_FILE"
    "$LOG_DIR/load-bottleneck-observer.log"
    "$LOG_DIR/validator-watchdog.log"
    "$LOG_DIR/validator.log"
  )
  local node
  local path
  local reset_count=0

  for node in "${NODES[@]}"; do
    paths+=(
      "$LOG_DIR/validator-${node}.log"
      "$LOG_DIR/start-validator-${node}.log"
      "$LOG_DIR/rejoin-validator-${node}.log"
    )
  done

  for path in "${paths[@]}"; do
    if [ -f "$path" ]; then
      : > "$path"
      reset_count=$((reset_count + 1))
    fi
  done

  if [ "$reset_count" -gt 0 ]; then
    echo "  - Reset $reset_count log file(s)"
  else
    echo "  - No active runtime logs to reset"
  fi
}

preflight_cleanup() {
  echo "• Preflight cleanup (pid/port/runtime hygiene)"

  for node in "${NODES[@]}"; do
    cleanup_stale_pid_file "$PID_DIR/validator-${node}.pid"
  done
  cleanup_stale_pid_file "$OPS_PROXY_PID_FILE"
  cleanup_stale_pid_file "$PID_DIR/caffeinate.pid"

  local java_pids
  java_pids="$(find_validator_processes)"
  if [ -n "$java_pids" ]; then
    echo "• Found validator processes: $java_pids"
    echo "  -> Sending TERM signal..."
    echo "$java_pids" | xargs kill 2>/dev/null || true
    sleep 3
    java_pids="$(find_validator_processes)"
    if [ -n "$java_pids" ]; then
      echo "  -> Force killing remaining processes: $java_pids"
      echo "$java_pids" | xargs kill -9 2>/dev/null || true
    fi
  fi

  local port_list=("${HTTP_PORTS[@]}")
  for node in "${NODES[@]}"; do
    port_list+=($((ODD_HTTP_BASE_PORT + (node * VALIDATOR_HTTP_PORT_STEP))))
  done
  for node in "${NODES[@]}"; do
    for offset in 0 1 2 3 4 5 6; do
      port_list+=($((AERON_CLUSTER_BASE_PORT + (node * 100) + offset)))
    done
  done
  port_list+=("$OPS_PROXY_PORT")
  kill_ports "${port_list[@]}"

  cleanup_validator_runtime_state
  cleanup_aeron_runtime
  reset_active_runtime_logs
}

build_consensus_jars() {
  local jr_oak_dir="$OAK_ROOT/jackrabbit-oak"
  local build_targets=""
  local build_label=""
  if [ ! -d "$jr_oak_dir" ]; then
    echo "❌ Cannot build: jackrabbit-oak not found at $jr_oak_dir"
    return 1
  fi
  if ! command -v mvn >/dev/null 2>&1; then
    echo "❌ Cannot build: mvn not found"
    return 1
  fi

  build_targets="$(validator_reactor_modules "$jr_oak_dir")"
  build_label="${build_targets//,/ + }"
  echo "• Building $build_label..."
  (
    cd "$jr_oak_dir"
    mvn -pl "$build_targets" -am package -DskipTests
  )
}

consensus_jar_is_stale() {
  local consensus_jar="$OAK_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
  local -a watch_roots=(
    "$OAK_ROOT/jackrabbit-oak/oak-segment-consensus/src/main/java"
  )
  if [ -d "$OAK_ROOT/jackrabbit-oak/oak-segment-agentic/src/main/java" ] && \
     [ -f "$OAK_ROOT/jackrabbit-oak/pom.xml" ] && \
     grep -q '<module>oak-segment-agentic</module>' "$OAK_ROOT/jackrabbit-oak/pom.xml"; then
    watch_roots+=("$OAK_ROOT/jackrabbit-oak/oak-segment-agentic/src/main/java")
  fi

  if [ ! -f "$consensus_jar" ]; then
    return 0
  fi

  local root
  for root in "${watch_roots[@]}"; do
    if [ -d "$root" ] && find "$root" -type f -newer "$consensus_jar" -print -quit | grep -q .; then
      return 0
    fi
  done

  return 1
}

warn_if_consensus_jar_stale() {
  if [ "$BUILD_ON_START" = "true" ]; then
    return 0
  fi

  if consensus_jar_is_stale; then
    echo "⚠️  oak-segment-consensus.jar appears stale relative to runtime sources."
    echo "   Launch will use the existing jar unless you pass --build."
    echo "   This can reproduce fixed runtime bugs during mock/test runs."
  fi
}

ipfs_api_is_ready() {
  local base="$1"
  # Kubo accepts POST for /api/v0/* endpoints.
  curl -sS -X POST --max-time 2 "$base/api/v0/version" >/dev/null 2>&1 || \
    curl -sS -X POST --max-time 2 "$base/api/v0/id" >/dev/null 2>&1
}

try_ipfs_api_candidates() {
  local base="$IPFS_API_HTTP"
  local alt=""
  if [ "$IPFS_API_HTTP" = "http://127.0.0.1:5001" ]; then
    alt="http://localhost:5001"
  elif [ "$IPFS_API_HTTP" = "http://localhost:5001" ]; then
    alt="http://127.0.0.1:5001"
  fi

  if ipfs_api_is_ready "$base"; then
    IPFS_API_HTTP="$base"
    return 0
  fi
  if [ -n "$alt" ] && ipfs_api_is_ready "$alt"; then
    IPFS_API_HTTP="$alt"
    return 0
  fi
  return 1
}

start_ipfs_daemon_if_needed() {
  if [ "$AUTO_START_IPFS" != "true" ]; then
    return 0
  fi
  if ! command -v ipfs >/dev/null 2>&1; then
    return 0
  fi

  cleanup_stale_ipfs_pid_file
  local tracked_pid
  tracked_pid="$(ipfs_pid_from_file)"
  if is_ipfs_daemon_pid "$tracked_pid"; then
    echo "• IPFS daemon already tracked (PID: $tracked_pid)"
    return 0
  elif [ -n "$tracked_pid" ]; then
    echo "⚠️  Ignoring stale IPFS pid file entry ($tracked_pid is not ipfs daemon)"
    rm -f "$IPFS_PID_FILE" 2>/dev/null || true
  fi

  if ipfs_process_running; then
    echo "• IPFS daemon process detected (PID: $(find_ipfs_daemon_pid)); skipping auto-start and waiting for API readiness"
    return 0
  fi

  echo "• Attempting to auto-start IPFS daemon..."
  if [ ! -d "$HOME/.ipfs" ]; then
    echo "  - Initializing IPFS repo at $HOME/.ipfs"
    if ! ipfs init >/dev/null 2>&1; then
      echo "⚠️  Failed to initialize IPFS repo automatically"
      return 1
    fi
    # Kubo's default gateway (8080) is often taken; serve it where the validators look for it.
    local gateway_addr
    gateway_addr="$(oak_ipfs_gateway_multiaddr "$IPFS_LOCAL_GATEWAY_BASE")"
    if [ -n "$gateway_addr" ]; then
      echo "  - Setting IPFS gateway address to $gateway_addr"
      ipfs config Addresses.Gateway "$gateway_addr" >/dev/null 2>&1 \
        || echo "⚠️  Could not set Addresses.Gateway; run: $(oak_ipfs_gateway_fix_hint "$IPFS_LOCAL_GATEWAY_BASE")"
    fi
  fi

  : > "$IPFS_DAEMON_LOG_FILE"
  if ! launch_detached_process "$IPFS_PID_FILE" "$IPFS_DAEMON_LOG_FILE" ipfs daemon; then
    echo "❌ Failed to launch IPFS daemon"
    rm -f "$IPFS_PID_FILE" 2>/dev/null || true
    return 1
  fi
  local ipfs_pid
  ipfs_pid="$(ipfs_pid_from_file)"
  if [ -z "$ipfs_pid" ]; then
    ipfs_pid="$(find_ipfs_daemon_pid)"
    if is_ipfs_daemon_pid "$ipfs_pid"; then
      echo "$ipfs_pid" > "$IPFS_PID_FILE"
    fi
  fi
  if [ -n "$ipfs_pid" ]; then
    echo "  - IPFS daemon started (PID: $ipfs_pid)"
  else
    echo "  - IPFS daemon start issued; waiting for API readiness"
  fi
  echo "  - Logs: $IPFS_DAEMON_LOG_FILE"
  sleep 1
  if ! is_pid_alive "$ipfs_pid"; then
    ipfs_pid="$(find_ipfs_daemon_pid)"
    if is_ipfs_daemon_pid "$ipfs_pid"; then
      echo "$ipfs_pid" > "$IPFS_PID_FILE"
      return 0
    fi
    echo "❌ IPFS daemon exited immediately after startup"
    if [ -f "$IPFS_DAEMON_LOG_FILE" ]; then
      echo "   Last daemon log lines:"
      tail -n 40 "$IPFS_DAEMON_LOG_FILE" || true
    fi
    rm -f "$IPFS_PID_FILE" 2>/dev/null || true
    return 1
  fi
  return 0
}

wait_for_ipfs_api() {
  local deadline=$(( $(date +%s) + IPFS_READY_TIMEOUT_SECONDS ))

  echo "• Waiting for IPFS API readiness (base: $IPFS_API_HTTP)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if try_ipfs_api_candidates; then
      echo "✅ IPFS API ready ($IPFS_API_HTTP)"
      return 0
    fi
    sleep 1
  done

  echo "❌ IPFS API not ready after ${IPFS_READY_TIMEOUT_SECONDS}s (base: $IPFS_API_HTTP)"
  echo "   Start IPFS daemon and retry:"
  echo "   ipfs daemon"
  if [ -f "$IPFS_PID_FILE" ]; then
    pid="$(cat "$IPFS_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! is_pid_alive "$pid"; then
      echo "   Note: tracked IPFS PID is not alive ($pid)"
    fi
  fi
  if [ -f "$IPFS_DAEMON_LOG_FILE" ]; then
    echo "   Auto-start log: $IPFS_DAEMON_LOG_FILE"
    echo "   Last daemon log lines:"
    tail -n 40 "$IPFS_DAEMON_LOG_FILE" || true
  fi
  return 1
}

ensure_ipfs_ready() {
  if try_ipfs_api_candidates; then
    return 0
  fi
  start_ipfs_daemon_if_needed || true
  wait_for_ipfs_api
}

if command -v ipfs >/dev/null 2>&1; then
  if ipfs_process_running; then
    echo "✅ IPFS daemon detected"
  else
    echo "⚠️  IPFS daemon process not detected (will rely on API readiness check)"
  fi
else
  echo "⚠️  ipfs CLI not found; checking API endpoint directly"
fi

if ! ensure_ipfs_ready; then
  exit 1
fi

# An existing ~/.ipfs repo keeps its own Addresses.Gateway. Fail when it sits on one of this
# cluster's ports (validator-4's standby is 8099 in a 5-member cluster on base 8090); otherwise
# only warn that the validators' local gateway links point elsewhere.
check_ipfs_gateway_port() {
  local expected daemon_ports port cluster_ports
  expected="$(oak_guard_url_port "$IPFS_LOCAL_GATEWAY_BASE")"
  daemon_ports="$(oak_ipfs_daemon_gateway_ports "$IPFS_API_HTTP")"
  [ -n "$daemon_ports" ] || return 0
  cluster_ports=" $(oak_guard_cluster_ports "$CLUSTER_SIZE" "$VALIDATOR_HTTP_BASE_PORT" "$VALIDATOR_HTTP_PORT_STEP" "$AERON_CLUSTER_BASE_PORT" | tr '\n' ' ') $OPS_PROXY_PORT "
  for port in $daemon_ports; do
    case "$cluster_ports" in
      *" $port "*)
        echo "❌ The IPFS daemon's gateway listens on port $port, which this ${CLUSTER_SIZE}-member cluster needs."
        echo "   Move the gateway (with the daemon stopped): $(oak_ipfs_gateway_fix_hint "$IPFS_LOCAL_GATEWAY_BASE")"
        echo "   then restart the daemon. See TROUBLESHOOTING.md (IPFS gateway on a validator port)."
        return 1
        ;;
    esac
  done
  case " $(echo "$daemon_ports" | tr '\n' ' ') " in
    *" $expected "*) return 0 ;;
  esac
  echo "⚠️  The IPFS daemon's gateway listens on port(s) $(echo "$daemon_ports" | tr '\n' ' ')but IPFS_LOCAL_GATEWAY_BASE is $IPFS_LOCAL_GATEWAY_BASE."
  echo "   Validators will hand out local gateway links that do not resolve. To align the daemon (stopped):"
  echo "   $(oak_ipfs_gateway_fix_hint "$IPFS_LOCAL_GATEWAY_BASE")"
}
if ! check_ipfs_gateway_port; then
  exit 1
fi

warn_if_consensus_jar_stale

if [ "$BUILD_ON_START" = "true" ]; then
  build_consensus_jars
  # Build can take long enough for externally managed daemons to disappear; re-validate before startup.
  if ! ensure_ipfs_ready; then
    exit 1
  fi
fi

ensure_cluster_wallet

echo "• Starting cluster '$CLUSTER_NAME'"
echo "  Runtime root: $CLUSTER_RUNTIME_ROOT"
echo "  HTTP base port: $VALIDATOR_HTTP_BASE_PORT"
echo "  Aeron base port: $AERON_CLUSTER_BASE_PORT"
echo "  OPS proxy port: $OPS_PROXY_PORT"

for node in "${NODES[@]}"; do
  cleanup_stale_pid_file "$PID_DIR/validator-${node}.pid"
done
cleanup_stale_pid_file "$OPS_PROXY_PID_FILE"

if [ "$FRESH" = "true" ]; then
  preflight_cleanup
fi

# Members still running from an earlier launch keep the IPFS_GATEWAY_BASE they were launched
# with, and it is written into committed content. Refuse to launch the rest with another value
# (records from before the gateway was recorded imply the old 8099 default).
require_gateway_matches_running_members() {
  local record="$PID_DIR/cluster-launch.env" recorded node running=""
  [ -f "$record" ] || return 0
  for node in "${NODES[@]}"; do
    if is_pid_alive "$(cat "$PID_DIR/validator-${node}.pid" 2>/dev/null || true)"; then
      running="$running validator-$node"
    fi
  done
  [ -n "$running" ] || return 0
  recorded="$(oak_launch_record_get "$record" IPFS_GATEWAY_BASE || echo "$OAK_LEGACY_IPFS_GATEWAY_BASE")"
  [ "$recorded" = "$IPFS_GATEWAY_BASE" ] && return 0
  echo "❌ Running members ($running ) were launched with IPFS_GATEWAY_BASE=$recorded;"
  echo "   this start would launch the others with IPFS_GATEWAY_BASE=$IPFS_GATEWAY_BASE."
  echo "   The gateway base is written into committed content, so members must agree. Either"
  echo "   export IPFS_GATEWAY_BASE=$recorded IPFS_LOCAL_GATEWAY_BASE=$recorded, or stop the cluster first."
  return 1
}
if ! require_gateway_matches_running_members; then
  exit 1
fi

# Membership-critical launch settings, read by member.sh (and the mock console) so a member
# restarted on its own rejoins with exactly the membership its peers were launched with.
# EXTRA_JAVA_OPTS carries the sharding flags of multi-cluster topologies; without it a
# restarted member would come back unsharded. Format: lib/launch-record.sh.
write_launch_record() {
  oak_launch_record_write "$PID_DIR/cluster-launch.env" \
    "OAK_CLUSTER_NAME=$CLUSTER_NAME" \
    "OAK_CLUSTER_SIZE=$CLUSTER_SIZE" \
    "OAK_VALIDATOR_HTTP_BASE_PORT=$VALIDATOR_HTTP_BASE_PORT" \
    "OAK_VALIDATOR_HTTP_PORT_STEP=$VALIDATOR_HTTP_PORT_STEP" \
    "AERON_CLUSTER_BASE_PORT=$AERON_CLUSTER_BASE_PORT" \
    "AERON_DIR_BASE=${AERON_DIR_BASE:-}" \
    "AERON_RAMDISK_ROOT=${AERON_RAMDISK_ROOT:-}" \
    "OAK_MOCK_EPOCH_DURATION_SECONDS=$MOCK_EPOCH_SECONDS" \
    "OAK_BLOCKCHAIN_MODE=$OAK_BLOCKCHAIN_MODE" \
    "OPS_PROXY_PORT=$OPS_PROXY_PORT" \
    "IPFS_API_HTTP=$IPFS_API_HTTP" \
    "IPFS_GATEWAY_BASE=$IPFS_GATEWAY_BASE" \
    "IPFS_LOCAL_GATEWAY_BASE=$IPFS_LOCAL_GATEWAY_BASE" \
    "EXTRA_JAVA_OPTS=${EXTRA_JAVA_OPTS:-}" \
    "LAUNCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
if ! write_launch_record; then
  exit 1
fi

for node in "${NODES[@]}"; do
  pid_file="$PID_DIR/validator-${node}.pid"
  if [ -f "$pid_file" ] && is_pid_alive "$(cat "$pid_file" 2>/dev/null || true)"; then
    echo "• Validator-$node already running (PID $(cat "$pid_file"))"
    continue
  fi

  if ! ensure_ipfs_ready; then
    echo "❌ IPFS is not ready; aborting validator startup before node-$node launch."
    exit 1
  fi

  rm -f "$pid_file"
  echo "• Starting validator-$node"
  OAK_MOCK_EPOCH_DURATION_SECONDS="$MOCK_EPOCH_SECONDS" \
    launch_detached_process "$pid_file" "$LOG_DIR/start-validator-${node}.log" \
    "$VALIDATOR_SCRIPT" "$node"
  sleep 1

done

if [ -f "$OPS_PROXY_PID_FILE" ] && is_pid_alive "$(cat "$OPS_PROXY_PID_FILE" 2>/dev/null || true)"; then
  echo "• OPS proxy already running (PID $(cat "$OPS_PROXY_PID_FILE"))"
else
  rm -f "$OPS_PROXY_PID_FILE"
  if [ ! -d "$OPS_EDGE_WORKER_DIR" ]; then
    echo "⚠️  OPS proxy skipped: edge worker repo not found at $OPS_EDGE_WORKER_DIR"
  elif [ ! -f "$OPS_EDGE_WORKER_DIR/src/ops-api-worker.mjs" ]; then
    echo "⚠️  OPS proxy skipped: src/ops-api-worker.mjs missing in $OPS_EDGE_WORKER_DIR"
  else
    echo "• Starting OPS proxy on :$OPS_PROXY_PORT (mode=$OPS_PROXY_MODE upstream=$OPS_PROXY_UPSTREAM)"
    OPS_MOCK_MODE="$OPS_PROXY_MODE" \
      OPS_UPSTREAM_BASE="$OPS_PROXY_UPSTREAM" \
      OPS_MOCK_PORT="$OPS_PROXY_PORT" \
      launch_detached_process "$OPS_PROXY_PID_FILE" "$OPS_PROXY_LOG_FILE" \
        bash -lc "cd \"$OPS_EDGE_WORKER_DIR\" && exec node src/ops-api-worker.mjs"
    sleep 1
  fi
fi

if [ "$NO_CAFFEINATE" = "false" ] && [ -x "$PREVENT_SLEEP_SCRIPT" ]; then
  PID_DIR="$PID_DIR" "$PREVENT_SLEEP_SCRIPT" start >/dev/null 2>&1 || true
fi

if [ "$ENABLE_WATCHDOG" = "true" ] && [ -x "$WATCHDOG_SCRIPT" ]; then
  WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}" \
    OAK_CLUSTER_SIZE="$CLUSTER_SIZE" \
    "$WATCHDOG_SCRIPT" --start >/dev/null 2>&1 || true
fi

if [ "$ENABLE_LOAD_OBSERVER" = "true" ] && [ -x "$LOAD_OBSERVER_SCRIPT" ]; then
  OBSERVER_INTERVAL_SECONDS="${OBSERVER_INTERVAL_SECONDS:-5}" \
    OAK_CLUSTER_SIZE="$CLUSTER_SIZE" \
    "$LOAD_OBSERVER_SCRIPT" --start >/dev/null 2>&1 || true
fi

deadline=$(( $(date +%s) + WAIT_SECONDS ))
all_up=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  healthy_count=0
  for port in "${HTTP_PORTS[@]}"; do
    code="$(curl -s -o /tmp/oak-start-health-$port.json -w "%{http_code}" "http://127.0.0.1:$port/health" || echo 000)"
    if [ "$code" = "200" ]; then
      healthy_count=$((healthy_count + 1))
    fi
  done
  ops_code="$(curl -s -o /tmp/oak-start-ops.json -w "%{http_code}" "http://127.0.0.1:$OPS_PROXY_PORT/ops/v1/overview" || echo 000)"
  if [ "$healthy_count" -eq "${#HTTP_PORTS[@]}" ] && [ "$ops_code" = "200" ]; then
    all_up=true
    break
  fi
  sleep 1
done

if [ "$all_up" = "true" ]; then
  echo "✅ Cluster and OPS proxy are healthy."
else
  healthy_count=0
  for port in "${HTTP_PORTS[@]}"; do
    code="$(curl -s -o /tmp/oak-start-final-health-$port.json -w "%{http_code}" "http://127.0.0.1:$port/health" || echo 000)"
    if [ "$code" = "200" ]; then
      healthy_count=$((healthy_count + 1))
    fi
  done
  ops_code="$(curl -s -o /tmp/oak-start-final-ops.json -w "%{http_code}" "http://127.0.0.1:$OPS_PROXY_PORT/ops/v1/overview" || echo 000)"
  if [ "$healthy_count" -eq "${#HTTP_PORTS[@]}" ] && [ "$ops_code" = "200" ]; then
    echo "✅ Cluster and OPS proxy are healthy."
  else
    echo "⚠️  Startup submitted but not fully healthy within ${WAIT_SECONDS}s."
    echo "   Check status with: $SCRIPT_DIR/status-cluster.sh"
  fi
fi
