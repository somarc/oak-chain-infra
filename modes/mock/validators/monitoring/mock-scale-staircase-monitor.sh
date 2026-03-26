#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$BASE_DIR/lifecycle"
CONFIG_DIR="$BASE_DIR/config"

BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")

RUN_LOG="${RUN_LOG:-/tmp/oak-mock-scale-staircase-overnight.log}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/oak-mock-scale-staircase-artifacts}"
MONITOR_INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-30}"
MONITOR_TIMEOUT_SECONDS="${MONITOR_TIMEOUT_SECONDS:-0}"
STALL_SECONDS="${STALL_SECONDS:-900}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-0}"
CONFIRMATION_ATTEMPTS="${CONFIRMATION_ATTEMPTS:-3}"
CONFIRMATION_SLEEP_SECONDS="${CONFIRMATION_SLEEP_SECONDS:-5}"
TAIL_LINES="${TAIL_LINES:-400}"
REPORT_ROOT="${REPORT_ROOT:-$ARTIFACT_ROOT/monitoring}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${REPORT_DIR:-$REPORT_ROOT/mock-scale-staircase-monitor-$TIMESTAMP}"
MONITOR_LOG_FILE="${MONITOR_LOG_FILE:-$REPORT_DIR/monitor.log}"
STATE_FILE="${STATE_FILE:-$REPORT_DIR/latest-state.env}"
DRY_RUN="${DRY_RUN:-false}"

SINGLE_CLUSTER_3_CONFIG="${SINGLE_CLUSTER_3_CONFIG:-$CONFIG_DIR/single-cluster-3.env}"
SINGLE_CLUSTER_5_CONFIG="${SINGLE_CLUSTER_5_CONFIG:-$CONFIG_DIR/single-cluster-5.env}"
DUAL_CLUSTER_A_CONFIG="${DUAL_CLUSTER_A_CONFIG:-$CONFIG_DIR/5x3-cluster-a.env}"
DUAL_CLUSTER_B_CONFIG="${DUAL_CLUSTER_B_CONFIG:-$CONFIG_DIR/5x3-cluster-b.env}"
FABRIC_CLUSTER_A_CONFIG="${FABRIC_CLUSTER_A_CONFIG:-$CONFIG_DIR/5x3x3-cluster-a.env}"
FABRIC_CLUSTER_B_CONFIG="${FABRIC_CLUSTER_B_CONFIG:-$CONFIG_DIR/5x3x3-cluster-b.env}"
FABRIC_CLUSTER_C_CONFIG="${FABRIC_CLUSTER_C_CONFIG:-$CONFIG_DIR/5x3x3-cluster-c.env}"

usage() {
  cat <<'EOF'
Usage: ./mock-scale-staircase-monitor.sh [options]

Monitors a running mock-scale-staircase overnight run via its run log and
artifact root. Prints periodic progress snapshots and captures an investigation
bundle if the run stalls or fails.

Options:
  --run-log <path>              Staircase run log to watch
  --artifact-root <path>        Staircase artifact root
  --report-root <path>          Directory for monitor reports
  --interval <seconds>          Poll interval between snapshots
  --timeout-seconds <seconds>   Max runtime before a timeout investigation (0 = forever)
  --stall-seconds <seconds>     No-progress threshold before stall handling
  --start-timeout <seconds>     Max time to wait for the run log to appear (0 = forever)
  --confirmation-attempts <n>   Re-check terminal conditions before declaring them
  --confirmation-sleep <sec>    Sleep between confirmation checks
  --tail-lines <n>              Number of run-log lines to include in reports
  --dry-run                    Print one snapshot and exit
  -h, --help                    Show this help

Defaults:
  run log:      /tmp/oak-mock-scale-staircase-overnight.log
  artifact root:/tmp/oak-mock-scale-staircase-artifacts
EOF
}

mkdir -p "$REPORT_DIR"
: > "$MONITOR_LOG_FILE"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$MONITOR_LOG_FILE"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log "ERROR: Missing required command: $cmd"
    exit 1
  }
}

file_mtime_epoch() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  if stat -f '%m' "$file" >/dev/null 2>&1; then
    stat -f '%m' "$file"
    return 0
  fi
  stat -c '%Y' "$file"
}

file_size_bytes() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
    return 0
  fi
  stat -c '%s' "$file"
}

last_relevant_line() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 0
  fi
  awk '
    /PHASE [0-9]+\/[0-9]+ .* started/ { line = $0 }
    /RUN step=[0-9]+\/[0-9]+/ { line = $0 }
    /DONE step=[0-9]+\/[0-9]+/ { line = $0 }
    /SUCCESS mock-scale-staircase completed/ { line = $0 }
    /ERROR: .*failed/ { line = $0 }
    END { if (line != "") print line }
  ' "$file"
}

parse_progress_line() {
  local line="$1"
  local state="running"
  local step="unset"
  local total_steps="unset"
  local percent="unset"
  local phase="unset"
  local total_phases="unset"
  local name="unset"

  if [[ "$line" =~ SUCCESS[[:space:]]mock-scale-staircase[[:space:]]completed ]]; then
    state="completed"
  elif [[ "$line" =~ ERROR:.*failed ]]; then
    state="failed"
  fi

  if [[ "$line" =~ RUN[[:space:]]step=([0-9]+)/([0-9]+)[[:space:]]percent=([0-9]+)%[[:space:]]phase=([0-9]+)/([0-9]+)[[:space:]]name=(.*) ]]; then
    step="${BASH_REMATCH[1]}"
    total_steps="${BASH_REMATCH[2]}"
    percent="${BASH_REMATCH[3]}"
    phase="${BASH_REMATCH[4]}"
    total_phases="${BASH_REMATCH[5]}"
    name="${BASH_REMATCH[6]}"
  elif [[ "$line" =~ DONE[[:space:]]step=([0-9]+)/([0-9]+)[[:space:]]percent=([0-9]+)%[[:space:]]duration=([0-9]+)s[[:space:]]name=(.*) ]]; then
    step="${BASH_REMATCH[1]}"
    total_steps="${BASH_REMATCH[2]}"
    percent="${BASH_REMATCH[3]}"
    name="${BASH_REMATCH[5]}"
  elif [[ "$line" =~ PHASE[[:space:]]([0-9]+)/([0-9]+)[[:space:]]([^[:space:]]+)[[:space:]]steps=([0-9]+)[[:space:]]started ]]; then
    phase="${BASH_REMATCH[1]}"
    total_phases="${BASH_REMATCH[2]}"
    name="${BASH_REMATCH[3]}"
  fi

  printf '%s|%s|%s|%s|%s|%s|%s\n' "$state" "$step" "$total_steps" "$percent" "$phase" "$total_phases" "$name"
}

read_run_snapshot() {
  local now mtime size age line parsed state step total_steps percent phase total_phases name
  now="$(date +%s)"
  if [ ! -f "$RUN_LOG" ]; then
    printf 'missing|0|0|0|unset|unset|unset|unset|unset|unset|unset\n'
    return 0
  fi

  mtime="$(file_mtime_epoch "$RUN_LOG")"
  size="$(file_size_bytes "$RUN_LOG")"
  age=$((now - mtime))
  line="$(last_relevant_line "$RUN_LOG")"
  parsed="$(parse_progress_line "$line")"
  IFS='|' read -r state step total_steps percent phase total_phases name <<<"$parsed"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$state" "$step" "$total_steps" "$percent" "$phase" "$total_phases" "$name" "$age" "$size" "$line" "$mtime"
}

snapshot_state_line() {
  local snapshot="$1"
  IFS='|' read -r state step total_steps percent phase total_phases name age size line mtime <<<"$snapshot"
  cat <<EOF
state=$state
step=$step
total_steps=$total_steps
percent=$percent
phase=$phase
total_phases=$total_phases
name=$name
age_seconds=$age
size_bytes=$size
mtime_epoch=$mtime
last_line=$(printf '%s' "$line" | sed 's/"/\\"/g')
EOF
}

print_snapshot() {
  local snapshot="$1"
  IFS='|' read -r state step total_steps percent phase total_phases name age size line mtime <<<"$snapshot"
  log "state=$state age=${age}s size=${size}B last=\"${line:-no-progress-yet}\""
  if [ "$step" != "unset" ] && [ "$phase" != "unset" ]; then
    log "progress phase=${phase}/${total_phases} step=${step}/${total_steps} percent=${percent}% name=${name}"
  elif [ "$phase" != "unset" ]; then
    log "progress phase=${phase}/${total_phases} name=${name}"
  fi
}

write_state_file() {
  local snapshot="$1"
  snapshot_state_line "$snapshot" > "$STATE_FILE"
}

load_cluster_env() {
  local cluster_config="$1"
  set -a
  for cfg in "${BASE_CONFIGS[@]}" "$cluster_config"; do
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
    else
      log "ERROR: Missing config file: $cfg"
      return 1
    fi
  done
  set +a
}

cluster_status_cmd() {
  local label="$1"
  case "$label" in
    single-cluster-3)
      echo "status-cluster"
      ;;
    single-cluster-5)
      echo "status-cluster"
      ;;
    dual-5x3)
      echo "status-3x2"
      ;;
    triple-5x3x3)
      echo "status-3x3"
      ;;
    *)
      echo "status-cluster"
      ;;
  esac
}

cluster_status_args() {
  local label="$1"
  case "$label" in
    single-cluster-3)
      printf '%s\n' "$SINGLE_CLUSTER_3_CONFIG"
      ;;
    single-cluster-5)
      printf '%s\n' "$SINGLE_CLUSTER_5_CONFIG"
      ;;
    dual-5x3)
      printf '%s\n%s\n' "$DUAL_CLUSTER_A_CONFIG" "$DUAL_CLUSTER_B_CONFIG"
      ;;
    triple-5x3x3)
      printf '%s\n%s\n%s\n' "$FABRIC_CLUSTER_A_CONFIG" "$FABRIC_CLUSTER_B_CONFIG" "$FABRIC_CLUSTER_C_CONFIG"
      ;;
    *)
      return 1
      ;;
  esac
}

retry_run() {
  local attempts="$1"
  local sleep_seconds="$2"
  shift 2
  local attempt=1
  local last_rc=0
  while [ "$attempt" -le "$attempts" ]; do
    if "$@"; then
      return 0
    fi
    last_rc=$?
    if [ "$attempt" -ge "$attempts" ]; then
      return "$last_rc"
    fi
    log "retry=${attempt}/${attempts} failed for: $*"
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done
  return "$last_rc"
}

capture_topology_status() {
  local label="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"

  case "$label" in
    single-cluster-3)
      retry_run 3 2 bash -lc "
        set -euo pipefail
        source \"$CONFIG_DIR/mock.env\"
        source \"$CONFIG_DIR/ipfs.env\"
        source \"$SINGLE_CLUSTER_3_CONFIG\"
        \"$LIFECYCLE_DIR/status-cluster.sh\"
      " > "$out_dir/status.txt" 2>&1 || true
      ;;
    single-cluster-5)
      retry_run 3 2 bash -lc "
        set -euo pipefail
        source \"$CONFIG_DIR/mock.env\"
        source \"$CONFIG_DIR/ipfs.env\"
        source \"$SINGLE_CLUSTER_5_CONFIG\"
        \"$LIFECYCLE_DIR/status-cluster.sh\"
      " > "$out_dir/status.txt" 2>&1 || true
      ;;
    dual-5x3)
      retry_run 3 2 "$LIFECYCLE_DIR/status-3x2.sh" \
        --cluster-a-config "$DUAL_CLUSTER_A_CONFIG" \
        --cluster-b-config "$DUAL_CLUSTER_B_CONFIG" \
        > "$out_dir/status.txt" 2>&1 || true
      ;;
    triple-5x3x3)
      retry_run 3 2 "$LIFECYCLE_DIR/status-3x3.sh" \
        --cluster-a-config "$FABRIC_CLUSTER_A_CONFIG" \
        --cluster-b-config "$FABRIC_CLUSTER_B_CONFIG" \
        --cluster-c-config "$FABRIC_CLUSTER_C_CONFIG" \
        > "$out_dir/status.txt" 2>&1 || true
      ;;
  esac
}

collect_triage_report() {
  local log_dir="$1"
  local out_file="$2"
  if [ -d "$log_dir" ]; then
    retry_run 3 2 "$BASE_DIR/monitoring/triage-validator-logs.sh" \
      --log-dir "$log_dir" \
      --out "$out_file" \
      --since-lines "$TAIL_LINES" >/dev/null 2>&1 || true
  fi
}

infer_active_topology() {
  local snapshot="$1"
  local line="$2"
  if [[ "$line" =~ phase-01-single-cluster-3 ]]; then
    echo "single-cluster-3"
  elif [[ "$line" =~ phase-02-single-cluster-5 ]]; then
    echo "single-cluster-5"
  elif [[ "$line" =~ phase-03-dual-5x3 ]]; then
    echo "dual-5x3"
  elif [[ "$line" =~ phase-04-triple-5x3x3 ]]; then
    echo "triple-5x3x3"
  elif [[ "$line" =~ phase-05-soak ]]; then
    echo "triple-5x3x3"
  else
    echo "unknown"
  fi
}

derive_likely_cause() {
  local tail_file="$1"
  if rg -n "Aeron port overlap detected" "$tail_file" >/dev/null 2>&1; then
    echo "Aeron port overlap or topology collision"
    return 0
  fi
  if rg -n "no_quorum|Cluster unhealthy: no_quorum" "$tail_file" >/dev/null 2>&1; then
    echo "quorum loss or recovery window"
    return 0
  fi
  if rg -n "HTTP 000000|Connection refused|status=DOWN" "$tail_file" >/dev/null 2>&1; then
    echo "validator or proxy stopped answering"
    return 0
  fi
  if rg -n "Missing proposalId|proposal v1 contract|OPERATION_FAILED" "$tail_file" >/dev/null 2>&1; then
    echo "proposal contract mismatch"
    return 0
  fi
  if rg -n "Expected CID|binary retention|ipfsCid" "$tail_file" >/dev/null 2>&1; then
    echo "binary/IPFS retention mismatch"
    return 0
  fi
  if rg -n "rate_limit_exceeded|429" "$tail_file" >/dev/null 2>&1; then
    echo "rate limiting interference"
    return 0
  fi
  echo "undetermined; inspect status and log evidence"
}

write_investigation_report() {
  local snapshot="$1"
  local tail_file="$2"
  local report_dir="$3"
  local active_topology="$4"
  local state="$5"
  local likely_cause="$6"

  mkdir -p "$report_dir"

  {
    echo "# Mock Staircase Investigation"
    echo
    echo "As of: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "State: $state"
    echo "Active topology: $active_topology"
    echo "Likely cause: $likely_cause"
    echo
    echo "## Live Snapshot"
    echo '```text'
    cat "$STATE_FILE" 2>/dev/null || true
    echo '```'
    echo
    echo "## Run Log Tail"
    echo '```text'
    cat "$tail_file"
    echo '```'
  } > "$report_dir/summary.md"

  local topo_dir status_out triage_out runtime_root
  for topo_dir in single-cluster-3 single-cluster-5 dual-5x3 triple-5x3x3; do
    capture_topology_status "$topo_dir" "$report_dir/status/$topo_dir"
  done

  for config in \
    "$SINGLE_CLUSTER_3_CONFIG" \
    "$SINGLE_CLUSTER_5_CONFIG" \
    "$DUAL_CLUSTER_A_CONFIG" \
    "$DUAL_CLUSTER_B_CONFIG" \
    "$FABRIC_CLUSTER_A_CONFIG" \
    "$FABRIC_CLUSTER_B_CONFIG" \
    "$FABRIC_CLUSTER_C_CONFIG"
  do
    if [ -f "$config" ]; then
      (
        load_cluster_env "$config"
        runtime_root="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
        mkdir -p "$report_dir/logs"
        cluster_name="${OAK_CLUSTER_NAME:-unknown}"
        local cluster_log_dir="$runtime_root/logs"
        triage_out="$report_dir/logs/${cluster_name}-triage.txt"
        collect_triage_report "$cluster_log_dir" "$triage_out"
        if [ -d "$cluster_log_dir" ]; then
          tail -n "$TAIL_LINES" "$cluster_log_dir"/validator-*.log > "$report_dir/logs/${cluster_name}-validators.tail.txt" 2>/dev/null || true
          tail -n "$TAIL_LINES" "$cluster_log_dir"/start-validator-*.log > "$report_dir/logs/${cluster_name}-startup.tail.txt" 2>/dev/null || true
        fi
      )
    fi
  done

  {
    echo "## Status Evidence"
    find "$report_dir/status" -type f | sort
    echo
    echo "## Log Evidence"
    find "$report_dir/logs" -type f | sort
  } >> "$report_dir/summary.md"

  log "investigation report written to $report_dir"
}

confirm_terminal_state() {
  local desired_state="$1"
  local initial_snapshot="$2"
  local confirmed=0
  local attempt
  local prev_line current_snapshot current_state current_step current_total current_percent current_phase current_total_phases current_name current_age current_size current_line current_mtime

  IFS='|' read -r prev_state prev_step prev_total prev_percent prev_phase prev_total_phases prev_name prev_age prev_size prev_line prev_mtime <<<"$initial_snapshot"

  for attempt in $(seq 1 "$CONFIRMATION_ATTEMPTS"); do
    sleep "$CONFIRMATION_SLEEP_SECONDS"
    current_snapshot="$(read_run_snapshot)"
    IFS='|' read -r current_state current_step current_total current_percent current_phase current_total_phases current_name current_age current_size current_line current_mtime <<<"$current_snapshot"
    if [ "$current_state" = "completed" ] || [ "$current_state" = "failed" ]; then
      if [ "$current_state" = "$desired_state" ]; then
        confirmed=$((confirmed + 1))
      fi
    fi
    if [ "$current_state" != "$desired_state" ]; then
      return 1
    fi
    if [ "$current_line" != "$prev_line" ] && [ "$desired_state" != "completed" ]; then
      return 1
    fi
  done

  [ "$confirmed" -ge 1 ]
}

confirm_stall_state() {
  local initial_snapshot="$1"
  local confirmed=0
  local attempt
  local prev_size prev_age prev_line prev_state prev_step prev_total prev_percent prev_phase prev_total_phases prev_name prev_mtime
  local current_snapshot current_state current_step current_total current_percent current_phase current_total_phases current_name current_age current_size current_line current_mtime

  IFS='|' read -r prev_state prev_step prev_total prev_percent prev_phase prev_total_phases prev_name prev_age prev_size prev_line prev_mtime <<<"$initial_snapshot"

  for attempt in $(seq 1 "$CONFIRMATION_ATTEMPTS"); do
    sleep "$CONFIRMATION_SLEEP_SECONDS"
    current_snapshot="$(read_run_snapshot)"
    IFS='|' read -r current_state current_step current_total current_percent current_phase current_total_phases current_name current_age current_size current_line current_mtime <<<"$current_snapshot"
    if [ "$current_state" = "completed" ] || [ "$current_state" = "failed" ]; then
      return 1
    fi
    if [ "$current_size" != "$prev_size" ] || [ "$current_line" != "$prev_line" ] || [ "$current_age" -lt "$prev_age" ]; then
      return 1
    fi
    confirmed=$((confirmed + 1))
  done

  [ "$confirmed" -ge 1 ]
}

main_loop() {
  local start_epoch now snapshot state step total_steps percent phase total_phases name age size line mtime active_topology tail_file report_dir likely_cause
  start_epoch="$(date +%s)"

  log "monitor started run_log=$RUN_LOG artifact_root=$ARTIFACT_ROOT stall_seconds=$STALL_SECONDS interval=${MONITOR_INTERVAL_SECONDS}s"

  while :; do
    if [ ! -f "$RUN_LOG" ]; then
      if [ "$START_TIMEOUT_SECONDS" -gt 0 ]; then
        now="$(date +%s)"
        if [ $((now - start_epoch)) -ge "$START_TIMEOUT_SECONDS" ]; then
          log "ERROR: run log did not appear within ${START_TIMEOUT_SECONDS}s"
          exit 1
        fi
      fi
      log "state=waiting run log not present yet"
      sleep "$MONITOR_INTERVAL_SECONDS"
      continue
    fi

    snapshot="$(read_run_snapshot)"
    IFS='|' read -r state step total_steps percent phase total_phases name age size line mtime <<<"$snapshot"
    write_state_file "$snapshot"
    print_snapshot "$snapshot"

    if [ "$MONITOR_TIMEOUT_SECONDS" -gt 0 ]; then
      now="$(date +%s)"
      if [ $((now - start_epoch)) -ge "$MONITOR_TIMEOUT_SECONDS" ] && [ "$state" != "completed" ]; then
        log "monitor detected timeout after ${MONITOR_TIMEOUT_SECONDS}s"
        active_topology="$(infer_active_topology "$snapshot" "$line")"
        tail_file="$REPORT_DIR/run-log-tail.txt"
        tail -n "$TAIL_LINES" "$RUN_LOG" > "$tail_file" 2>/dev/null || true
        likely_cause="monitor timeout threshold reached before staircase completion"
        report_dir="$REPORT_ROOT/mock-scale-staircase-investigation-$TIMESTAMP"
        write_investigation_report "$snapshot" "$tail_file" "$report_dir" "$active_topology" "timeout" "$likely_cause"
        log "monitor exiting with timeout after investigation"
        exit 1
      fi
    fi

    if [ "$state" = "completed" ]; then
      log "monitor detected completion"
      exit 0
    fi

    if [ "$state" = "failed" ]; then
      log "monitor detected failure; confirming before investigation"
      if confirm_terminal_state "failed" "$snapshot"; then
        active_topology="$(infer_active_topology "$snapshot" "$line")"
        tail_file="$REPORT_DIR/run-log-tail.txt"
        tail -n "$TAIL_LINES" "$RUN_LOG" > "$tail_file" 2>/dev/null || true
        likely_cause="$(derive_likely_cause "$tail_file")"
        report_dir="$REPORT_ROOT/mock-scale-staircase-investigation-$TIMESTAMP"
        write_investigation_report "$snapshot" "$tail_file" "$report_dir" "$active_topology" "$state" "$likely_cause"
        log "monitor exiting with failure after investigation"
        exit 1
      fi
      log "failure not confirmed on retry; continuing monitor loop"
      sleep "$MONITOR_INTERVAL_SECONDS"
      continue
    fi

    if [ "$age" -ge "$STALL_SECONDS" ]; then
      log "monitor detected possible stall age=${age}s threshold=${STALL_SECONDS}s"
      if confirm_stall_state "$snapshot"; then
        active_topology="$(infer_active_topology "$snapshot" "$line")"
        tail_file="$REPORT_DIR/run-log-tail.txt"
        tail -n "$TAIL_LINES" "$RUN_LOG" > "$tail_file" 2>/dev/null || true
        likely_cause="$(derive_likely_cause "$tail_file")"
        report_dir="$REPORT_ROOT/mock-scale-staircase-investigation-$TIMESTAMP"
        write_investigation_report "$snapshot" "$tail_file" "$report_dir" "$active_topology" "stalled" "$likely_cause"
        log "monitor exiting with stall after investigation"
        exit 1
      fi
      log "stall not confirmed on retry; continuing monitor loop"
    fi

    sleep "$MONITOR_INTERVAL_SECONDS"
  done
}

while (($# > 0)); do
  case "$1" in
    --run-log)
      shift
      RUN_LOG="${1:?missing path}"
      ;;
    --artifact-root)
      shift
      ARTIFACT_ROOT="${1:?missing path}"
      ;;
    --report-root)
      shift
      REPORT_ROOT="${1:?missing path}"
      ;;
    --interval)
      shift
      MONITOR_INTERVAL_SECONDS="${1:?missing integer}"
      ;;
    --timeout-seconds)
      shift
      MONITOR_TIMEOUT_SECONDS="${1:?missing integer}"
      ;;
    --stall-seconds)
      shift
      STALL_SECONDS="${1:?missing integer}"
      ;;
    --start-timeout)
      shift
      START_TIMEOUT_SECONDS="${1:?missing integer}"
      ;;
    --confirmation-attempts)
      shift
      CONFIRMATION_ATTEMPTS="${1:?missing integer}"
      ;;
    --confirmation-sleep)
      shift
      CONFIRMATION_SLEEP_SECONDS="${1:?missing integer}"
      ;;
    --tail-lines)
      shift
      TAIL_LINES="${1:?missing integer}"
      ;;
    --dry-run)
      DRY_RUN="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "ERROR: Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$REPORT_ROOT"

require_cmd awk
require_cmd curl
require_cmd rg
require_cmd sed
require_cmd tail

snapshot="$(read_run_snapshot)"
write_state_file "$snapshot"
print_snapshot "$snapshot"

if [ "$DRY_RUN" = "true" ]; then
  exit 0
fi

main_loop
