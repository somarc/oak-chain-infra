#!/bin/bash
set -euo pipefail

# shellcheck source=lib/root-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/root-guard.sh"
CLUSTER_NAME="${OAK_CLUSTER_NAME:-single-cluster}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
OPS_PROXY_PID_FILE="$PID_DIR/ops-proxy.pid"
PREVENT_SLEEP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prevent-sleep.sh"
WATCHDOG_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/load-bottleneck-observer.sh"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-}"
VALIDATOR_HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
VALIDATOR_HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
AERON_CLUSTER_BASE_PORT="${AERON_CLUSTER_BASE_PORT:-9000}"
AERON_GLOBAL_TMP_CLEANUP="${AERON_GLOBAL_TMP_CLEANUP:-false}"
VALIDATOR_PROCESS_MATCH="${VALIDATOR_PROCESS_MATCH:-$CLUSTER_RUNTIME_ROOT/validator-}"
OPS_PROXY_PORT="${OPS_PROXY_PORT:-8787}"
NODES=()
HTTP_PORTS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cluster-size 3|5] [--keep-runtime]

Options:
  --cluster-size N  Stop scope for expected mock cluster size (3 or 5). Default: auto(0..4).
  --keep-runtime   Skip Aeron media directory cleanup.

A plain stop keeps each member's Aeron cluster log and archive (validator-N/aeron-cluster-node-N):
they belong with the Oak store and are only reset together with it (start-cluster.sh --fresh).
STOP_WAIT_SECONDS (default 30) bounds the graceful SIGTERM wait before SIGKILL.
EOF
}

KEEP_RUNTIME=false
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-30}"
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
    echo "${AERON_RAMDISK_ROOT%/}/${CLUSTER_NAME}/aeron-media"
  fi
}

for node in "${NODES[@]}"; do
  HTTP_PORTS+=($((VALIDATOR_HTTP_BASE_PORT + (node * VALIDATOR_HTTP_PORT_STEP))))
  HTTP_PORTS+=($((VALIDATOR_HTTP_BASE_PORT + 1 + (node * VALIDATOR_HTTP_PORT_STEP))))
done

find_validator_processes() {
  local pattern
  if [ -n "$VALIDATOR_PROCESS_MATCH" ]; then
    pattern="oak-segment-consensus.*${VALIDATOR_PROCESS_MATCH}"
  else
    pattern="oak-segment-consensus.*${CLUSTER_RUNTIME_ROOT}"
  fi
  pgrep -f "$pattern" 2>/dev/null || true
}

is_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_validator_processes() {
  local java_pids
  java_pids="$(find_validator_processes)"
  if [ -z "$java_pids" ]; then
    echo "• No validator processes found"
    return
  fi

  echo "• Found validator processes: $java_pids"
  echo "  -> Sending TERM signal..."
  echo "$java_pids" | xargs kill 2>/dev/null || true
  # shellcheck disable=SC2086
  wait_graceful $java_pids
}

# SIGTERM was sent; give the validators up to STOP_WAIT_SECONDS to shut Aeron and Oak down
# cleanly (same budget as member.sh), then SIGKILL whatever is left.
wait_graceful() {
  local waited=0 pid alive
  [ "$#" -gt 0 ] || return 0
  while [ "$waited" -lt "$STOP_WAIT_SECONDS" ]; do
    alive=()
    for pid in "$@"; do is_pid_alive "$pid" && alive+=("$pid"); done
    [ "${#alive[@]}" -eq 0 ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  for pid in "$@"; do
    if is_pid_alive "$pid"; then
      echo "  - force kill $pid (still running after ${STOP_WAIT_SECONDS}s)"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}

# Stop stays available on every root (it is how the live cluster is stopped), so it is scoped
# instead of gated: only listeners that belong to this runtime root are killed.
kill_ports() {
  oak_guard_kill_owned_ports "$CLUSTER_RUNTIME_ROOT" "$PID_DIR" "$@"
}

# A pid file can outlive its process and the pid can be reused: only signal a recorded pid
# whose command line still matches what the file claims to track.
pid_matches() {
  local pid="$1" expect="$2" cmd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in *"$expect"*) return 0 ;; esac
  return 1
}

cleanup_aeron_runtime() {
  local username
  local custom_aeron_dir_base
  local cleaned_count=0
  username="$(whoami)"
  custom_aeron_dir_base="$(resolved_aeron_dir_base)"
  # Media (driver) dirs only. aeron-cluster-node-N holds the cluster log and archive, which must
  # survive a stop: a member restarted without them starts a new log over a populated Oak store.
  echo "• Cleaning Aeron media directories (cluster log and archive kept)"
  for node in "${NODES[@]}"; do
    local path
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
      rm -rf "$path" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
    fi
    if [ -n "$custom_aeron_dir_base" ]; then
      path="${custom_aeron_dir_base}-${node}-driver"
      if [ -d "$path" ]; then
        echo "  - Removing: $path"
        rm -rf "$path" 2>/dev/null && cleaned_count=$((cleaned_count + 1)) || true
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
    echo "• Cleaned $cleaned_count Aeron media directory(ies)"
  fi
}

stopping_pids=()
for node in "${NODES[@]}"; do
  pid_file="$PID_DIR/validator-${node}.pid"
  if [ ! -f "$pid_file" ]; then
    echo "• Validator-$node not running (no pid file)"
    continue
  fi

  pid="$(cat "$pid_file")"
  if is_pid_alive "$pid" && ! pid_matches "$pid" "$CLUSTER_RUNTIME_ROOT/validator-$node"; then
    echo "• Validator-$node pid file points at pid $pid, which is not validator-$node of $CLUSTER_RUNTIME_ROOT; not signalling it"
  elif is_pid_alive "$pid"; then
    echo "• Stopping validator-$node (PID $pid)"
    kill "$pid" || true
    stopping_pids+=("$pid")
  else
    echo "• Validator-$node pid file stale"
  fi
  rm -f "$pid_file"
done
if [ "${#stopping_pids[@]}" -gt 0 ]; then wait_graceful "${stopping_pids[@]}"; fi

if [ -f "$OPS_PROXY_PID_FILE" ]; then
  ops_pid="$(cat "$OPS_PROXY_PID_FILE")"
  if is_pid_alive "$ops_pid" && ! pid_matches "$ops_pid" "ops-api-worker"; then
    echo "• OPS proxy pid file points at pid $ops_pid, which is not an ops-api-worker; not signalling it"
  elif is_pid_alive "$ops_pid"; then
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

stop_validator_processes

port_list=("${HTTP_PORTS[@]}" "$OPS_PROXY_PORT")
for node in "${NODES[@]}"; do
  for offset in 0 1 2 3 4 5 6; do
    port_list+=($((AERON_CLUSTER_BASE_PORT + (node * 100) + offset)))
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
  PID_DIR="$PID_DIR" "$WATCHDOG_SCRIPT" --stop >/dev/null 2>&1 || true
fi

if [ -x "$LOAD_OBSERVER_SCRIPT" ]; then
  PID_DIR="$PID_DIR" "$LOAD_OBSERVER_SCRIPT" --stop >/dev/null 2>&1 || true
fi

echo "✅ Stop sequence complete for cluster '$CLUSTER_NAME'"
