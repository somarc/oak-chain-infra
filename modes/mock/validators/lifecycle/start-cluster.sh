#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_SCRIPT="$SCRIPT_DIR/../debug/run-validator-node.sh"
PREVENT_SLEEP_SCRIPT="$SCRIPT_DIR/prevent-sleep.sh"
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
WAIT_SECONDS="${WAIT_SECONDS:-45}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$HOME/oak-chain/cluster-keystore.properties}"
NODES=()
HTTP_PORTS=()

mkdir -p "$PID_DIR" "$LOG_DIR"
export OAK_ROOT

usage() {
  cat <<EOF
Usage: $(basename "$0") [--fresh] [--cluster-size 3|5] [--reset-cluster-wallet] [--no-caffeinate] [--wait-seconds N]

Options:
  --fresh            Stop validators/proxy, clean Aeron runtime dirs, then start clean.
  --cluster-size N   Aeron member count for mock cluster (3 or 5). Default: $CLUSTER_SIZE.
  --reset-cluster-wallet  Delete and regenerate cluster wallet before startup.
  --no-caffeinate    Do not start sleep prevention.
  --wait-seconds N   Readiness wait timeout (default: $WAIT_SECONDS).
EOF
}

FRESH=false
NO_CAFFEINATE=false
RESET_CLUSTER_WALLET=false
while (($# > 0)); do
  case "$1" in
    --fresh) FRESH=true ;;
    --cluster-size)
      shift
      if [ -z "${1:-}" ] || { [ "$1" != "3" ] && [ "$1" != "5" ]; }; then
        echo "Invalid --cluster-size value (use 3 or 5)"
        usage
        exit 1
      fi
      CLUSTER_SIZE="$1"
      ;;
    --no-caffeinate) NO_CAFFEINATE=true ;;
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

if ! command -v ipfs >/dev/null 2>&1; then
  echo "⚠️  ipfs CLI not found; skipping daemon check"
else
  if ! pgrep -f "ipfs daemon" >/dev/null 2>&1; then
    echo "⚠️  IPFS daemon is not running. Start it with: ipfs daemon"
  else
    echo "✅ IPFS daemon detected"
  fi
fi

ensure_cluster_wallet

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

  rm -f "$pid_file"
  echo "• Starting validator-$node"
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
