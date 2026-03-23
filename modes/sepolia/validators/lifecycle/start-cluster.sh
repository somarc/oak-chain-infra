#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_SCRIPT="$SCRIPT_DIR/../debug/run-validator-node.sh"
PREVENT_SLEEP_SCRIPT="$SCRIPT_DIR/prevent-sleep.sh"
WATCHDOG_SCRIPT="$SCRIPT_DIR/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$SCRIPT_DIR/../monitoring/load-bottleneck-observer.sh"
PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
OAK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
# Preferred location: dedicated edge worker repo. Keep OPS_DASHBOARD_DIR as fallback for compatibility.
OPS_EDGE_WORKER_DIR="${OPS_EDGE_WORKER_DIR:-$OAK_ROOT/oak-chain-edge-worker}"
if [ -n "${OPS_DASHBOARD_DIR:-}" ] && [ "${OPS_DASHBOARD_DIR:-}" != "$OPS_EDGE_WORKER_DIR" ]; then
  OPS_EDGE_WORKER_DIR="$OPS_DASHBOARD_DIR"
fi
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"
OPS_PROXY_LOG_FILE="$LOG_DIR/start-ops-proxy.log"
OPS_PROXY_PORT="${OPS_PROXY_PORT:-8787}"
OPS_PROXY_MODE="${OPS_PROXY_MODE:-proxy}"
OPS_PROXY_UPSTREAM="${OPS_PROXY_UPSTREAM:-http://127.0.0.1:8090}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
MOCK_EPOCH_SECONDS="${OAK_MOCK_EPOCH_DURATION_SECONDS:-300}"
ENABLE_WATCHDOG="${ENABLE_WATCHDOG:-true}"
ENABLE_LOAD_OBSERVER="${ENABLE_LOAD_OBSERVER:-true}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$HOME/oak-chain/cluster-keystore.properties}"
MODE_CONFIG_FILE="${MODE_CONFIG_FILE:-$SCRIPT_DIR/../config/sepolia.env}"
IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"
IPFS_READY_TIMEOUT_SECONDS="${IPFS_READY_TIMEOUT_SECONDS:-30}"
AUTO_START_IPFS="${AUTO_START_IPFS:-true}"
IPFS_DAEMON_LOG_FILE="${IPFS_DAEMON_LOG_FILE:-$LOG_DIR/ipfs-daemon.log}"
IPFS_PID_FILE="${IPFS_PID_FILE:-$PID_DIR/ipfs-daemon.pid}"
NODES=()
HTTP_PORTS=()

mkdir -p "$PID_DIR" "$LOG_DIR"
export OAK_ROOT

usage() {
  cat <<EOF
Usage: $(basename "$0") [--fresh] [--build] [--cluster-size 3|5] [--config path] [--rpc-url URL] [--contract-address 0x...] [--reset-cluster-wallet] [--no-caffeinate] [--wait-seconds N]

Options:
  --fresh            Stop validators/proxy, clean Aeron runtime dirs, then start clean.
  --build            Build consensus jars before startup (oak-segment-consensus + oak-segment-agentic).
  --cluster-size N   Aeron member count for local cluster (3 or 5). Default: $CLUSTER_SIZE.
  --config path      Sepolia mode env file to source (default: $MODE_CONFIG_FILE).
  --rpc-url URL      Override OAK_BLOCKCHAIN_RPC_URL.
  --contract-address 0x... Override OAK_BLOCKCHAIN_CONTRACT_ADDRESS.
  --mock-epoch-seconds N  Optional epoch override for local pacing tests (default: $MOCK_EPOCH_SECONDS).
  --reset-cluster-wallet  Delete and regenerate cluster wallet before startup.
  --no-caffeinate    Do not start sleep prevention.
  --wait-seconds N   Readiness wait timeout (default: $WAIT_SECONDS).
  --no-watchdog      Disable validator failure watchdog auto-start.
  --no-load-observer Disable load bottleneck observer auto-start.

Environment:
  IPFS_API_HTTP              IPFS API base URL (default: $IPFS_API_HTTP)
  IPFS_READY_TIMEOUT_SECONDS Max seconds to wait for IPFS API readiness (default: $IPFS_READY_TIMEOUT_SECONDS)
  AUTO_START_IPFS            Auto-start IPFS daemon if API is unavailable (default: $AUTO_START_IPFS)
  IPFS_DAEMON_LOG_FILE       Log file for auto-started IPFS daemon (default: $IPFS_DAEMON_LOG_FILE)
  IPFS_PID_FILE              PID file for auto-started IPFS daemon (default: $IPFS_PID_FILE)
  OAK_PROPOSAL_BATCH_MAX                Queue sender batch max (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_FINALIZATION_CHUNK_SIZE  Finalization chunk size (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_FINALIZATION_CHUNK_DELAY_MS Delay between finalization chunks in ms (default 0)
  OAK_PROPOSAL_PERSISTENCE_ENABLED      true|false queue durability persistence (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_PERSISTENCE_FLUSH_MS     Proposal queue persistence flush interval ms (OSGi cfg + optional JVM fallback)
  OAK_PROPOSAL_PERSISTENCE_FLUSH_BATCH  Proposal queue persistence flush batch size (OSGi cfg + optional JVM fallback)
  OAK_CONSENSUS_MAX_PENDING_MESSAGES    Backpressure pending cap (OSGi cfg + optional JVM fallback)
  OAK_CONSENSUS_BACKPRESSURE_TIMEOUT_MS Backpressure timeout ms (OSGi cfg + optional JVM fallback)
  OAK_QUEUE_TUNING_SYSTEM_PROP_FALLBACK true|false (default true). Keep JVM -D fallback while validating OSGi pickup.
  MODE_CONFIG_FILE                      Sepolia mode env file (default: $MODE_CONFIG_FILE)
EOF
}

load_mode_config() {
  if [ ! -f "$MODE_CONFIG_FILE" ]; then
    echo "❌ Missing Sepolia config file: $MODE_CONFIG_FILE"
    echo "   Create one from: $SCRIPT_DIR/../config/sepolia.env.example"
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$MODE_CONFIG_FILE"
  set +a
}

validate_sepolia_config() {
  if [ "${OAK_BLOCKCHAIN_MODE:-}" != "sepolia" ]; then
    echo "• Forcing OAK_BLOCKCHAIN_MODE=sepolia"
    export OAK_BLOCKCHAIN_MODE="sepolia"
  fi

  if [ -z "${OAK_BLOCKCHAIN_RPC_URL:-}" ]; then
    echo "❌ OAK_BLOCKCHAIN_RPC_URL is required for Sepolia mode"
    return 1
  fi
  if [ -z "${OAK_BLOCKCHAIN_CONTRACT_ADDRESS:-}" ]; then
    echo "❌ OAK_BLOCKCHAIN_CONTRACT_ADDRESS is required for Sepolia mode"
    return 1
  fi

  case "$OAK_BLOCKCHAIN_RPC_URL" in
    http://*|https://*) ;;
    *)
      echo "❌ OAK_BLOCKCHAIN_RPC_URL must be an http(s) URL"
      return 1
      ;;
  esac
}

FRESH=false
NO_CAFFEINATE=false
RESET_CLUSTER_WALLET=false
BUILD_ON_START=false
RPC_URL_OVERRIDE=""
CONTRACT_ADDRESS_OVERRIDE=""
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
    --config)
      shift
      if [ -z "${1:-}" ]; then
        echo "Missing value for --config"
        usage
        exit 1
      fi
      MODE_CONFIG_FILE="$1"
      ;;
    --rpc-url)
      shift
      if [ -z "${1:-}" ]; then
        echo "Missing value for --rpc-url"
        usage
        exit 1
      fi
      RPC_URL_OVERRIDE="$1"
      ;;
    --contract-address)
      shift
      if [ -z "${1:-}" ]; then
        echo "Missing value for --contract-address"
        usage
        exit 1
      fi
      CONTRACT_ADDRESS_OVERRIDE="$1"
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

if ! load_mode_config; then
  exit 1
fi

if [ -n "$RPC_URL_OVERRIDE" ]; then
  export OAK_BLOCKCHAIN_RPC_URL="$RPC_URL_OVERRIDE"
fi
if [ -n "$CONTRACT_ADDRESS_OVERRIDE" ]; then
  export OAK_BLOCKCHAIN_CONTRACT_ADDRESS="$CONTRACT_ADDRESS_OVERRIDE"
fi

if ! validate_sepolia_config; then
  exit 1
fi

if [ "$CLUSTER_SIZE" != "3" ] && [ "$CLUSTER_SIZE" != "5" ]; then
  echo "Invalid OAK_CLUSTER_SIZE=$CLUSTER_SIZE (expected 3 or 5)"
  exit 1
fi
export OAK_CLUSTER_SIZE="$CLUSTER_SIZE"
export OAK_MOCK_EPOCH_DURATION_SECONDS="$MOCK_EPOCH_SECONDS"

if [ "$CLUSTER_SIZE" = "5" ]; then
  NODES=(0 1 2 3 4)
  HTTP_PORTS=(8090 8092 8094 8096 8098)
else
  NODES=(0 1 2)
  HTTP_PORTS=(8090 8092 8094)
fi

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

ipfs_process_running() {
  pgrep -f "(ipfs|kubo) daemon" >/dev/null 2>&1
}

ipfs_pid_from_file() {
  if [ -f "$IPFS_PID_FILE" ]; then
    cat "$IPFS_PID_FILE" 2>/dev/null || true
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

kill_ports() {
  for port in "$@"; do
    local pids
    pids="$(lsof -ti :"$port" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      echo "• Clearing port $port"
      echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
  done
}

cleanup_aeron_runtime() {
  local username
  local cleaned_count=0
  username="$(whoami)"
  echo "• Cleaning Aeron runtime directories"
  for node in "${NODES[@]}"; do
    local path
    path="$HOME/oak-chain/validator-$node/aeron-cluster-node-$node"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
    fi
    path="$HOME/oak-chain/validator-$node/aeron-cluster-node-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
    path="$HOME/oak-chain/validator-$node/aeron-$username-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null || true
    fi
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

  if [ "$cleaned_count" -gt 0 ]; then
    echo "• Cleaned $cleaned_count Aeron cluster directory(ies)"
  fi
}

preflight_cleanup() {
  echo "• Preflight cleanup (pid/port/runtime hygiene)"

  for node in "${NODES[@]}"; do
    cleanup_stale_pid_file "$PID_DIR/validator-${node}.pid"
  done
  cleanup_stale_pid_file "$OPS_PROXY_PID_FILE"

  local java_pids
  java_pids="$(pgrep -f "oak-segment-consensus" 2>/dev/null || true)"
  if [ -n "$java_pids" ]; then
    echo "• Found validator processes: $java_pids"
    echo "  -> Sending TERM signal..."
    echo "$java_pids" | xargs kill 2>/dev/null || true
    sleep 3
    java_pids="$(pgrep -f "oak-segment-consensus" 2>/dev/null || true)"
    if [ -n "$java_pids" ]; then
      echo "  -> Force killing remaining processes: $java_pids"
      echo "$java_pids" | xargs kill -9 2>/dev/null || true
    fi
  fi

  local port_list=("${HTTP_PORTS[@]}")
  port_list+=(8091 8093 8095)
  for node in "${NODES[@]}"; do
    for offset in 0 1 2 3 4 5; do
      port_list+=($((9000 + (node * 100) + offset)))
    done
  done
  port_list+=("$OPS_PROXY_PORT")
  kill_ports "${port_list[@]}"

  cleanup_aeron_runtime
}

build_consensus_jars() {
  local jr_oak_dir="$OAK_ROOT/jackrabbit-oak"
  if [ ! -d "$jr_oak_dir" ]; then
    echo "❌ Cannot build: jackrabbit-oak not found at $jr_oak_dir"
    return 1
  fi
  if ! command -v mvn >/dev/null 2>&1; then
    echo "❌ Cannot build: mvn not found"
    return 1
  fi

  echo "• Building oak-segment-consensus and oak-segment-agentic..."
  (
    cd "$jr_oak_dir"
    mvn -pl oak-segment-consensus,oak-segment-agentic -am package -DskipTests
  )
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
    echo "• IPFS daemon process detected; skipping auto-start and waiting for API readiness"
    return 0
  fi

  echo "• Attempting to auto-start IPFS daemon..."
  if [ ! -d "$HOME/.ipfs" ]; then
    echo "  - Initializing IPFS repo at $HOME/.ipfs"
    if ! ipfs init >/dev/null 2>&1; then
      echo "⚠️  Failed to initialize IPFS repo automatically"
      return 1
    fi
  fi

  nohup ipfs daemon > "$IPFS_DAEMON_LOG_FILE" 2>&1 &
  local ipfs_pid=$!
  echo "$ipfs_pid" > "$IPFS_PID_FILE"
  echo "  - IPFS daemon started (PID: $ipfs_pid)"
  echo "  - Logs: $IPFS_DAEMON_LOG_FILE"
  sleep 1
  if ! is_pid_alive "$ipfs_pid"; then
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

if [ "$BUILD_ON_START" = "true" ]; then
  build_consensus_jars
  # Build can take long enough for externally managed daemons to disappear; re-validate before startup.
  if ! ensure_ipfs_ready; then
    exit 1
  fi
fi

ensure_cluster_wallet
echo "• Sepolia mode: rpc=$OAK_BLOCKCHAIN_RPC_URL"
echo "• Sepolia mode: contract=$OAK_BLOCKCHAIN_CONTRACT_ADDRESS"

for node in "${NODES[@]}"; do
  cleanup_stale_pid_file "$PID_DIR/validator-${node}.pid"
done
cleanup_stale_pid_file "$OPS_PROXY_PID_FILE"

if [ "$FRESH" = "true" ]; then
  preflight_cleanup
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
    nohup "$VALIDATOR_SCRIPT" "$node" > "$LOG_DIR/start-validator-${node}.log" 2>&1 &
  echo $! > "$pid_file"
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
    (
      cd "$OPS_EDGE_WORKER_DIR"
      OPS_MOCK_MODE="$OPS_PROXY_MODE" \
      OPS_UPSTREAM_BASE="$OPS_PROXY_UPSTREAM" \
      OPS_MOCK_PORT="$OPS_PROXY_PORT" \
      nohup node src/ops-api-worker.mjs > "$OPS_PROXY_LOG_FILE" 2>&1 &
      echo $! > "$OPS_PROXY_PID_FILE"
    )
    sleep 1
  fi
fi

if [ "$NO_CAFFEINATE" = "false" ] && [ -x "$PREVENT_SLEEP_SCRIPT" ]; then
  "$PREVENT_SLEEP_SCRIPT" start >/dev/null 2>&1 || true
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
