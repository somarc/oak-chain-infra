#!/bin/bash
set -euo pipefail

PID_DIR="${PID_DIR:-$HOME/oak-chain/pids}"
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"
PREVENT_SLEEP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prevent-sleep.sh"
WATCHDOG_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/load-bottleneck-observer.sh"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-}"
NODES=()
HTTP_PORTS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cluster-size 3|5] [--keep-runtime]

Options:
  --cluster-size N  Stop scope for expected local cluster size (3 or 5). Default: auto(0..4).
  --keep-runtime   Skip Aeron media directory cleanup.
EOF
}

KEEP_RUNTIME=false
while (($# > 0)); do
  case "$1" in
    --cluster-size)
      shift
      if [ -z "${1:-}" ] || { [ "$1" != "3" ] && [ "$1" != "5" ]; }; then
        echo "Invalid --cluster-size value (use 3 or 5)"
        usage
        exit 1
      fi
      CLUSTER_SIZE="$1"
      ;;
    --keep-runtime) KEEP_RUNTIME=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$CLUSTER_SIZE" = "3" ]; then
  NODES=(0 1 2)
elif [ "$CLUSTER_SIZE" = "5" ]; then
  NODES=(0 1 2 3 4)
else
  # Auto mode: aggressively clean both 3-node and 5-node leftovers
  NODES=(0 1 2 3 4)
fi

resolved_aeron_dir_base() {
  if [ -n "${AERON_DIR_BASE:-}" ]; then
    echo "${AERON_DIR_BASE%/}"
    return
  fi
  if [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
    echo "${AERON_RAMDISK_ROOT%/}/sepolia/aeron-media"
  fi
}

for node in "${NODES[@]}"; do
  HTTP_PORTS+=($((8090 + (node * 2))))
  HTTP_PORTS+=($((8091 + (node * 2))))
done

is_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_validator_processes() {
  local java_pids
  if [ -n "${VALIDATOR_PROCESS_MATCH:-}" ]; then
    java_pids="$(pgrep -f "oak-segment-consensus.*${VALIDATOR_PROCESS_MATCH}" 2>/dev/null || true)"
  else
    java_pids="$(pgrep -f "oak-segment-consensus.*${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}" 2>/dev/null || true)"
  fi
  if [ -z "$java_pids" ]; then
    echo "• No validator processes found"
    return
  fi

  echo "• Found validator processes: $java_pids"
  echo "  -> Sending TERM signal..."
  echo "$java_pids" | xargs kill 2>/dev/null || true
  sleep 3

  local remaining
  if [ -n "${VALIDATOR_PROCESS_MATCH:-}" ]; then
    remaining="$(pgrep -f "oak-segment-consensus.*${VALIDATOR_PROCESS_MATCH}" 2>/dev/null || true)"
  else
    remaining="$(pgrep -f "oak-segment-consensus.*${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}" 2>/dev/null || true)"
  fi
  if [ -n "$remaining" ]; then
    echo "  -> Force killing remaining processes: $remaining"
    echo "$remaining" | xargs kill -9 2>/dev/null || true
    sleep 1
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
  local custom_aeron_dir_base
  local cleaned_count=0
  username="$(whoami)"
  custom_aeron_dir_base="$(resolved_aeron_dir_base)"
  # Media (driver) dirs only: aeron-cluster-node-N holds the cluster log and archive, which must
  # survive a stop together with the Oak store.
  echo "• Cleaning Aeron media directories (cluster log and archive kept)"
  for node in "${NODES[@]}"; do
    local path
    path="$HOME/oak-chain/validator-$node/aeron-cluster-node-$node-driver"
    if [ -d "$path" ]; then
      echo "  - Removing: $path"
      rm -rf "$path" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
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
    echo "• Cleaned $cleaned_count Aeron media directory(ies)"
  fi
}

for node in "${NODES[@]}"; do
  pid_file="$PID_DIR/validator-${node}.pid"
  if [ ! -f "$pid_file" ]; then
    echo "• Validator-$node not running (no pid file)"
    continue
  fi

  pid="$(cat "$pid_file")"
  if is_pid_alive "$pid"; then
    echo "• Stopping validator-$node (PID $pid)"
    kill "$pid" || true
    waited=0
    while is_pid_alive "$pid" && [ "$waited" -lt "${STOP_WAIT_SECONDS:-30}" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if is_pid_alive "$pid"; then
      echo "  - force kill $pid (still running after ${STOP_WAIT_SECONDS:-30}s)"
      kill -9 "$pid" || true
    fi
  else
    echo "• Validator-$node pid file stale"
  fi
  rm -f "$pid_file"
done

if [ -f "$OPS_PROXY_PID_FILE" ]; then
  ops_pid="$(cat "$OPS_PROXY_PID_FILE")"
  if is_pid_alive "$ops_pid"; then
    echo "• Stopping OPS proxy (PID $ops_pid)"
    kill "$ops_pid" || true
    sleep 1
    if is_pid_alive "$ops_pid"; then
      echo "  - force kill $ops_pid"
      kill -9 "$ops_pid" || true
    fi
  else
    echo "• OPS proxy pid file stale"
  fi
  rm -f "$OPS_PROXY_PID_FILE"
else
  echo "• OPS proxy not running (no pid file)"
fi

ops_pids="$(pgrep -f "ops-api-(mock|worker)\\.mjs" 2>/dev/null || true)"
if [ -n "$ops_pids" ]; then
  echo "• Stopping lingering OPS proxy process(es): $ops_pids"
  echo "$ops_pids" | xargs kill 2>/dev/null || true
  sleep 1
  ops_pids="$(pgrep -f "ops-api-(mock|worker)\\.mjs" 2>/dev/null || true)"
  if [ -n "$ops_pids" ]; then
    echo "$ops_pids" | xargs kill -9 2>/dev/null || true
  fi
fi

stop_validator_processes

port_list=("${HTTP_PORTS[@]}")
for node in "${NODES[@]}"; do
  for offset in 0 1 2 3 4 5; do
    port_list+=($((9000 + (node * 100) + offset)))
  done
done
kill_ports "${port_list[@]}"

if [ "$KEEP_RUNTIME" = "false" ]; then
  cleanup_aeron_runtime
fi

if [ -x "$PREVENT_SLEEP_SCRIPT" ]; then
  PID_DIR="$PID_DIR" "$PREVENT_SLEEP_SCRIPT" stop >/dev/null 2>&1 || true
fi

if [ -x "$WATCHDOG_SCRIPT" ]; then
  "$WATCHDOG_SCRIPT" --stop >/dev/null 2>&1 || true
fi

if [ -x "$LOAD_OBSERVER_SCRIPT" ]; then
  "$LOAD_OBSERVER_SCRIPT" --stop >/dev/null 2>&1 || true
fi

echo "✅ Stop sequence complete"
