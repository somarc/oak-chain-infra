#!/bin/bash
# Per-member lifecycle for the local mock validator cluster.
#
# Each validator is an independent process that holds a fixed member id in a static Aeron
# membership. Stopping a member never shrinks the cluster: quorum stays a majority of the
# configured size. Whole-cluster lifecycle remains start-cluster.sh / stop-cluster.sh.
#
# Membership-critical settings (cluster size, ports, Aeron dirs) come from the launch record
# that start-cluster.sh writes to $PID_DIR/cluster-launch.env, so a restarted member rejoins
# with the membership its peers were launched with.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_SCRIPT="${VALIDATOR_SCRIPT:-$SCRIPT_DIR/../debug/run-validator-node.sh}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
PID_DIR="${PID_DIR:-$CLUSTER_RUNTIME_ROOT/pids}"
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
LAUNCH_RECORD="$PID_DIR/cluster-launch.env"
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-30}"
KILL_WAIT_SECONDS="${KILL_WAIT_SECONDS:-10}"
RECORD_KEYS="OAK_CLUSTER_NAME OAK_CLUSTER_SIZE OAK_VALIDATOR_HTTP_BASE_PORT OAK_VALIDATOR_HTTP_PORT_STEP AERON_CLUSTER_BASE_PORT AERON_DIR_BASE AERON_RAMDISK_ROOT OAK_MOCK_EPOCH_DURATION_SECONDS OAK_BLOCKCHAIN_MODE"
MEMBERSHIP_KEYS="OAK_CLUSTER_SIZE OAK_VALIDATOR_HTTP_BASE_PORT OAK_VALIDATOR_HTTP_PORT_STEP AERON_CLUSTER_BASE_PORT"

usage() {
  cat <<EOF
Usage: $(basename "$0") start|stop|kill|restart <member-id>
       $(basename "$0") status [member-id]

  start    Launch one validator. Clears its Aeron media-driver dir first; cluster/archive
           state is kept so the member catches up from its peers.
  stop     Graceful stop: SIGTERM, wait up to STOP_WAIT_SECONDS (default $STOP_WAIT_SECONDS), then SIGKILL.
  kill     Hard crash: SIGKILL immediately (fault injection).
  restart  stop, then start.
  status   Process and HTTP state for one member, or for all members.

Environment:
  CLUSTER_RUNTIME_ROOT  Runtime root (default: $CLUSTER_RUNTIME_ROOT)
  PID_DIR / LOG_DIR     Derived from CLUSTER_RUNTIME_ROOT unless set
  VALIDATOR_SCRIPT      Validator launcher (default: debug/run-validator-node.sh)
Membership (size, ports, Aeron dirs) is read from \$PID_DIR/cluster-launch.env when present.
EOF
}

load_launch_record() {
  [ -f "$LAUNCH_RECORD" ] || return 0
  local key value current
  while IFS='=' read -r key value; do
    case " $RECORD_KEYS " in *" $key "*) ;; *) continue ;; esac
    current="${!key:-}"
    if [ -z "$current" ]; then
      if [ -n "$value" ]; then export "$key=$value"; fi
    elif [ "$current" != "$value" ]; then
      case " $MEMBERSHIP_KEYS " in
        *" $key "*)
          echo "❌ $key=$current in your environment, but this cluster was launched with $key=$value"
          echo "   ($LAUNCH_RECORD). A member started with different membership cannot rejoin it."
          exit 1
          ;;
      esac
    fi
  done < "$LAUNCH_RECORD"
}

load_launch_record

CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
OAK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
# Same mock defaults start-cluster.sh applies, so a restarted member matches its peers.
export OAK_ROOT CLUSTER_RUNTIME_ROOT PID_DIR LOG_DIR
export OAK_CLUSTER_SIZE="$CLUSTER_SIZE"
export OAK_BLOCKCHAIN_MODE="${OAK_BLOCKCHAIN_MODE:-mock}"
export OAK_RATE_LIMIT_ENABLED="${OAK_RATE_LIMIT_ENABLED:-false}"
export OAK_CLUSTER_ENV="${OAK_CLUSTER_ENV:-test}"
export OAK_CLUSTER_SESSION_TIMEOUT_MINUTES="${OAK_CLUSTER_SESSION_TIMEOUT_MINUTES:-1}"
export OAK_MOCK_EPOCH_DURATION_SECONDS="${OAK_MOCK_EPOCH_DURATION_SECONDS:-300}"

member_port() { echo $((HTTP_BASE_PORT + ($1 * HTTP_PORT_STEP))); }
member_pid_file() { echo "$PID_DIR/validator-$1.pid"; }

read_pid() {
  if [ -f "$1" ]; then
    tr -d '[:space:]' < "$1" 2>/dev/null || true
  fi
}

is_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# A pid file can outlive its process and the pid can be reused. Only signal a process whose
# command line names this member's store directory.
member_pid() {
  local node="$1" pid cmd
  pid="$(read_pid "$(member_pid_file "$node")")"
  is_alive "$pid" || return 0
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in
    *"$CLUSTER_RUNTIME_ROOT/validator-$node"*) echo "$pid" ;;
  esac
}

wait_gone() {
  local pid="$1" limit="$2" waited=0
  while is_alive "$pid" && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  ! is_alive "$pid"
}

port_listener_pid() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true
}

member_media_dir() {
  local node="$1" base
  if [ -n "${AERON_DIR_BASE:-}" ]; then
    base="${AERON_DIR_BASE%/}"
  elif [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
    base="${AERON_RAMDISK_ROOT%/}/${OAK_CLUSTER_NAME:-single-cluster}/aeron-media"
  else
    base="$CLUSTER_RUNTIME_ROOT/validator-$node/aeron-media"
  fi
  echo "${base}-${node}-driver"
}

launch_detached() {
  local pid_file="$1" log_file="$2"
  shift 2
  mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >>"$log_file" 2>&1 < /dev/null &
    echo $! > "$pid_file"
    return 0
  fi
  python3 - "$pid_file" "$log_file" "$@" <<'PY'
import os
import sys

pid_file, log_file, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
if os.fork() > 0:
    os._exit(0)
os.setsid()
pid = os.fork()
if pid > 0:
    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{pid}\n")
    os._exit(0)
devnull = os.open(os.devnull, os.O_RDONLY)
os.dup2(devnull, 0)
with open(log_file, "ab", buffering=0) as log:
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
os.execvp(cmd[0], cmd)
PY
  local remaining=50
  while [ "$remaining" -gt 0 ] && [ -z "$(read_pid "$pid_file")" ]; do
    sleep 0.1
    remaining=$((remaining - 1))
  done
  [ -n "$(read_pid "$pid_file")" ]
}

start_member() {
  local node="$1" pid_file pid port holder media start_log
  pid_file="$(member_pid_file "$node")"
  pid="$(member_pid "$node")"
  if [ -n "$pid" ]; then
    echo "• validator-$node already running (pid $pid)"
    return 0
  fi
  port="$(member_port "$node")"
  holder="$(port_listener_pid "$port")"
  if [ -n "$holder" ]; then
    echo "❌ validator-$node port :$port is held by pid $holder, which $CLUSTER_RUNTIME_ROOT does not track."
    echo "   It may belong to a cluster launched under another CLUSTER_RUNTIME_ROOT. Refusing to start."
    return 1
  fi
  if [ ! -x "$VALIDATOR_SCRIPT" ]; then
    echo "❌ Validator launcher not found or not executable: $VALIDATOR_SCRIPT"
    return 1
  fi

  rm -f "$pid_file"
  media="$(member_media_dir "$node")"
  if [ -d "$media" ]; then
    echo "• Clearing Aeron media-driver dir: $media"
    rm -rf "$media"
  fi

  start_log="$LOG_DIR/start-validator-$node.log"
  echo "• Starting validator-$node (member $node of $CLUSTER_SIZE, http :$port)"
  if ! launch_detached "$pid_file" "$start_log" "$VALIDATOR_SCRIPT" "$node"; then
    echo "❌ Launch failed for validator-$node; see $start_log"
    return 1
  fi
  pid="$(read_pid "$pid_file")"
  sleep 1
  if ! is_alive "$pid"; then
    echo "❌ validator-$node exited immediately (pid ${pid:-unknown}). Last launcher output:"
    tail -n 20 "$start_log" 2>/dev/null | sed 's/^/   /' || true
    rm -f "$pid_file"
    return 1
  fi
  echo "✅ validator-$node launched (pid $pid). Log: $LOG_DIR/validator-$node.log"
}

stop_member() {
  local node="$1" signal="$2" pid pid_file waited=0
  pid_file="$(member_pid_file "$node")"
  pid="$(member_pid "$node")"
  if [ -z "$pid" ]; then
    echo "• validator-$node is not running"
    rm -f "$pid_file"
    return 0
  fi

  if [ "$signal" = "KILL" ]; then
    echo "• Hard-killing validator-$node (pid $pid, SIGKILL)"
    kill -9 "$pid" 2>/dev/null || true
    if ! wait_gone "$pid" "$KILL_WAIT_SECONDS"; then
      echo "❌ validator-$node (pid $pid) survived SIGKILL for ${KILL_WAIT_SECONDS}s"
      return 1
    fi
    rm -f "$pid_file"
    echo "✅ validator-$node killed"
    return 0
  fi

  echo "• Stopping validator-$node (pid $pid, SIGTERM; waiting up to ${STOP_WAIT_SECONDS}s)"
  kill "$pid" 2>/dev/null || true
  while is_alive "$pid" && [ "$waited" -lt "$STOP_WAIT_SECONDS" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if is_alive "$pid"; then
    echo "⚠️  validator-$node still running after ${STOP_WAIT_SECONDS}s; sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
    if ! wait_gone "$pid" "$KILL_WAIT_SECONDS"; then
      echo "❌ validator-$node (pid $pid) survived SIGKILL for ${KILL_WAIT_SECONDS}s"
      return 1
    fi
  fi
  rm -f "$pid_file"
  echo "✅ validator-$node stopped (${waited}s)"
}

status_member() {
  local node="$1" pid port code state
  pid="$(member_pid "$node")"
  port="$(member_port "$node")"
  code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$port/health/local" 2>/dev/null || true)"
  code="${code:-000}"
  if [ -n "$pid" ] && [ "$code" = "200" ]; then
    state=UP
  elif [ -n "$pid" ]; then
    state=STARTING
  elif [ "$code" = "200" ]; then
    state=UNTRACKED
  else
    state=DOWN
  fi
  echo "validator-$node state=$state pid=${pid:--} port=$port http=$code"
}

require_member() {
  local node="${1:-}"
  case "$node" in
    ''|*[!0-9]*)
      echo "❌ Expected a member id (0-$((CLUSTER_SIZE - 1)))"
      usage
      exit 1
      ;;
  esac
  if [ "$node" -ge "$CLUSTER_SIZE" ]; then
    echo "❌ Member $node is outside this ${CLUSTER_SIZE}-member cluster (ids 0-$((CLUSTER_SIZE - 1)))"
    exit 1
  fi
}

action="${1:-}"
case "$action" in
  start)
    require_member "${2:-}"
    start_member "$2"
    ;;
  stop)
    require_member "${2:-}"
    stop_member "$2" TERM
    ;;
  kill)
    require_member "${2:-}"
    stop_member "$2" KILL
    ;;
  restart)
    require_member "${2:-}"
    stop_member "$2" TERM
    start_member "$2"
    ;;
  status)
    if [ -n "${2:-}" ]; then
      require_member "$2"
      status_member "$2"
    else
      node=0
      while [ "$node" -lt "$CLUSTER_SIZE" ]; do
        status_member "$node"
        node=$((node + 1))
      done
    fi
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
