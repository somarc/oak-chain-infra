#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIFECYCLE_DIR="$TESTS_DIR/../lifecycle"
CONFIG_DIR="$TESTS_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")

SINGLE_CLUSTER_3_CONFIG="${SINGLE_CLUSTER_3_CONFIG:-$CONFIG_DIR/single-cluster-3.env}"
SINGLE_CLUSTER_5_CONFIG="${SINGLE_CLUSTER_5_CONFIG:-$CONFIG_DIR/single-cluster-5.env}"
DUAL_CLUSTER_A_CONFIG="${DUAL_CLUSTER_A_CONFIG:-$CONFIG_DIR/5x3-cluster-a.env}"
DUAL_CLUSTER_B_CONFIG="${DUAL_CLUSTER_B_CONFIG:-$CONFIG_DIR/5x3-cluster-b.env}"
FABRIC_CLUSTER_A_CONFIG="${FABRIC_CLUSTER_A_CONFIG:-$CONFIG_DIR/5x3x3-cluster-a.env}"
FABRIC_CLUSTER_B_CONFIG="${FABRIC_CLUSTER_B_CONFIG:-$CONFIG_DIR/5x3x3-cluster-b.env}"
FABRIC_CLUSTER_C_CONFIG="${FABRIC_CLUSTER_C_CONFIG:-$CONFIG_DIR/5x3x3-cluster-c.env}"

ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/oak-mock-scale-staircase-artifacts}"
RUN_LOG="${ARTIFACT_ROOT}/run.log"
BUILD_PENDING="${BUILD_PENDING:-true}"
AUTO_START_IPFS="${AUTO_START_IPFS:-true}"

RUN_SINGLE_CLUSTER_3_PHASE="${RUN_SINGLE_CLUSTER_3_PHASE:-true}"
RUN_SINGLE_CLUSTER_5_PHASE="${RUN_SINGLE_CLUSTER_5_PHASE:-true}"
RUN_DUAL_CLUSTER_PHASE="${RUN_DUAL_CLUSTER_PHASE:-true}"
RUN_TRIPLE_CLUSTER_PHASE="${RUN_TRIPLE_CLUSTER_PHASE:-true}"
RUN_BINARY_TESTS="${RUN_BINARY_TESTS:-true}"
RUN_WARM_FAILOVER="${RUN_WARM_FAILOVER:-true}"
WARM_FAILOVER_CYCLES="${WARM_FAILOVER_CYCLES:-3}"
STOP_AT_END="${STOP_AT_END:-false}"

SINGLE_CLUSTER_WRITE_COUNT_PER_ORG="${SINGLE_CLUSTER_WRITE_COUNT_PER_ORG:-72}"
DUAL_CLUSTER_WRITE_COUNT_PER_ORG="${DUAL_CLUSTER_WRITE_COUNT_PER_ORG:-72}"
FABRIC_LOCAL_WRITE_COUNT_PER_ORG="${FABRIC_LOCAL_WRITE_COUNT_PER_ORG:-24}"
SOAK_CYCLES="${SOAK_CYCLES:-0}"
SOAK_WRITE_COUNT_PER_ORG="${SOAK_WRITE_COUNT_PER_ORG:-8}"
SOAK_BINARY_INTERVAL="${SOAK_BINARY_INTERVAL:-3}"

usage() {
  cat <<'EOF'
Usage: ./mock-scale-staircase.sh

Phases:
  1. single-cluster 3-node acceptance
  2. single-cluster 5-node acceptance
  3. dual-cluster 5+3 distributed-fabric acceptance
  4. triple-cluster 5+3+3 distributed-fabric acceptance
  5. optional final-fabric soak cycles

Environment:
  ARTIFACT_ROOT=/tmp/oak-mock-scale-staircase-artifacts
  AUTO_START_IPFS=true|false
  BUILD_PENDING=true|false
  RUN_BINARY_TESTS=true|false
  RUN_WARM_FAILOVER=true|false
  WARM_FAILOVER_CYCLES=3
  SINGLE_CLUSTER_WRITE_COUNT_PER_ORG=72
  DUAL_CLUSTER_WRITE_COUNT_PER_ORG=72
  FABRIC_LOCAL_WRITE_COUNT_PER_ORG=24
  SOAK_CYCLES=0
  SOAK_WRITE_COUNT_PER_ORG=8
  SOAK_BINARY_INTERVAL=3
  STOP_AT_END=false
EOF
}

mkdir -p "$ARTIFACT_ROOT"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$RUN_LOG"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_cmd curl
require_cmd jq
require_cmd python3

load_cluster_env() {
  local cluster_config="$1"
  set -a
  for cfg in "${BASE_CONFIGS[@]}" "$cluster_config"; do
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
    else
      fail "Missing config file: $cfg"
    fi
  done
  set +a
}

run_with_cluster_env() {
  local cluster_config="$1"
  shift
  (
    load_cluster_env "$cluster_config"
    "$@"
  )
}

run_logged() {
  local description="$1"
  shift
  log "RUN ${description}"
  "$@" 2>&1 | tee -a "$RUN_LOG"
}

maybe_build_arg() {
  if [ "$BUILD_PENDING" = "true" ]; then
    BUILD_PENDING=false
    printf '%s\n' "--build"
  fi
}

stop_all_topologies() {
  log "Cleaning all known staircase topologies"
  "$LIFECYCLE_DIR/stop-cluster.sh" --cluster-size 5 >/dev/null 2>&1 || true
  "$LIFECYCLE_DIR/stop-cluster.sh" --cluster-size 3 >/dev/null 2>&1 || true
  "$LIFECYCLE_DIR/stop-3x2.sh" >/dev/null 2>&1 || true
  "$LIFECYCLE_DIR/stop-3x3.sh" >/dev/null 2>&1 || true
  "$LIFECYCLE_DIR/stop-3x2.sh" --cluster-a-config "$DUAL_CLUSTER_A_CONFIG" --cluster-b-config "$DUAL_CLUSTER_B_CONFIG" >/dev/null 2>&1 || true
  "$LIFECYCLE_DIR/stop-3x3.sh" --cluster-a-config "$FABRIC_CLUSTER_A_CONFIG" --cluster-b-config "$FABRIC_CLUSTER_B_CONFIG" --cluster-c-config "$FABRIC_CLUSTER_C_CONFIG" >/dev/null 2>&1 || true
}

start_single_cluster() {
  local cluster_config="$1"
  local build_arg=""
  build_arg="$(maybe_build_arg || true)"
  if [ -n "$build_arg" ]; then
    run_with_cluster_env "$cluster_config" "$LIFECYCLE_DIR/start-cluster.sh" --fresh "$build_arg" --no-watchdog --no-load-observer
  else
    run_with_cluster_env "$cluster_config" "$LIFECYCLE_DIR/start-cluster.sh" --fresh --no-watchdog --no-load-observer
  fi
}

start_dual_cluster() {
  local build_arg=""
  local -a args=(
    --cluster-a-config "$DUAL_CLUSTER_A_CONFIG"
    --cluster-b-config "$DUAL_CLUSTER_B_CONFIG"
    --fresh
  )
  build_arg="$(maybe_build_arg || true)"
  if [ -n "$build_arg" ]; then
    args=("$build_arg" "${args[@]}")
  fi
  "$LIFECYCLE_DIR/start-3x2.sh" "${args[@]}"
}

start_triple_cluster() {
  local build_arg=""
  local -a args=(
    --cluster-a-config "$FABRIC_CLUSTER_A_CONFIG"
    --cluster-b-config "$FABRIC_CLUSTER_B_CONFIG"
    --cluster-c-config "$FABRIC_CLUSTER_C_CONFIG"
    --fresh
  )
  build_arg="$(maybe_build_arg || true)"
  if [ -n "$build_arg" ]; then
    args=("$build_arg" "${args[@]}")
  fi
  "$LIFECYCLE_DIR/start-3x3.sh" "${args[@]}"
}

run_validator_api_smoke() {
  local cluster_config="$1"
  run_with_cluster_env "$cluster_config" bash "$TESTS_DIR/smoke/validator-api-smoke.sh"
}

run_status_cluster() {
  local cluster_config="$1"
  run_with_cluster_env "$cluster_config" "$LIFECYCLE_DIR/status-cluster.sh"
}

resolve_leader_port_for_config() {
  local cluster_config="$1"
  run_with_cluster_env "$cluster_config" bash -lc '
    node_count=3
    if [ "${OAK_CLUSTER_SIZE:-3}" = "5" ]; then
      node_count=5
    fi
    for ((idx=0; idx<node_count; idx++)); do
      port=$((OAK_VALIDATOR_HTTP_BASE_PORT + (idx * OAK_VALIDATOR_HTTP_PORT_STEP)))
      role="$(curl -s "http://127.0.0.1:${port}/v1/consensus/status" | jq -r ".currentRole // empty" 2>/dev/null || true)"
      if [ "$role" = "LEADER" ]; then
        printf "%s\n" "$port"
        exit 0
      fi
    done
    exit 1
  '
}

run_binary_upload() {
  local label="$1"
  local cluster_config="$2"
  local test_wallet="$3"
  local leader_port
  leader_port="$(resolve_leader_port_for_config "$cluster_config")" || fail "${label}: could not resolve leader port for binary test"
  log "BINARY ${label}: leader-port=${leader_port} wallet=${test_wallet}"
  VALIDATOR_URL="http://127.0.0.1:${leader_port}" TEST_WALLET="$test_wallet" \
    AUTO_START_IPFS="$AUTO_START_IPFS" IPFS_API_HTTP="$IPFS_API_HTTP" \
    bash "$TESTS_DIR/integration/test-binary-upload.sh"
}

run_warm_failover() {
  local cluster_config="$1"
  local cycles="$2"
  run_with_cluster_env "$cluster_config" env WARM_FAILOVER_CYCLES="$cycles" \
    bash "$TESTS_DIR/stability/aeron-warm-failover-smoke.sh"
}

run_quorum_envelope() {
  local cluster_config="$1"
  local wallet="$2"
  run_with_cluster_env "$cluster_config" env QUORUM_ENVELOPE_WALLET="$wallet" \
    bash "$TESTS_DIR/stability/aeron-quorum-envelope-smoke.sh"
}

run_single_cluster_surfaces() {
  local phase_artifact_root="$1"
  local cluster_config="$2"
  local write_count="$3"
  local run_stability="$4"
  local primary_wallet="$5"
  local secondary_wallet="$6"
  local smoke_wallet="$7"
  local failover_follower_wallet="$8"
  local failover_leader_wallet="$9"
  local catchup_wallet="${10}"
  local quorum_wallet="${11}"

  env \
    CLUSTER_CONFIG="$cluster_config" \
    START_CLUSTER=false \
    WRITE_COUNT_PER_ORG="$write_count" \
    RUN_STABILITY_SUITE="$run_stability" \
    ARTIFACT_ROOT="$phase_artifact_root" \
    PRIMARY_WALLET="$primary_wallet" \
    SECONDARY_WALLET="$secondary_wallet" \
    SMOKE_WALLET="$smoke_wallet" \
    FAILOVER_FOLLOWER_WALLET="$failover_follower_wallet" \
    FAILOVER_LEADER_WALLET="$failover_leader_wallet" \
    CATCHUP_WALLET="$catchup_wallet" \
    QUORUM_ENVELOPE_WALLET="$quorum_wallet" \
    bash "$TESTS_DIR/surfaces/proposal-surfaces-single-cluster.sh"
}

run_dual_cluster_surfaces() {
  local phase_artifact_root="$1"
  env \
    CLUSTER_A_CONFIG="$DUAL_CLUSTER_A_CONFIG" \
    CLUSTER_B_CONFIG="$DUAL_CLUSTER_B_CONFIG" \
    START_3X2=false \
    WRITE_COUNT_PER_ORG="$DUAL_CLUSTER_WRITE_COUNT_PER_ORG" \
    ARTIFACT_ROOT="$phase_artifact_root" \
    bash "$TESTS_DIR/surfaces/proposal-surfaces-3x2.sh"
}

run_dual_cluster_routing() {
  env \
    CLUSTER_A_CONFIG="$DUAL_CLUSTER_A_CONFIG" \
    CLUSTER_B_CONFIG="$DUAL_CLUSTER_B_CONFIG" \
    bash "$TESTS_DIR/routing/sharding-3x2-smoke.sh"
}

run_triple_cluster_routing() {
  env \
    CLUSTER_A_CONFIG="$FABRIC_CLUSTER_A_CONFIG" \
    CLUSTER_B_CONFIG="$FABRIC_CLUSTER_B_CONFIG" \
    CLUSTER_C_CONFIG="$FABRIC_CLUSTER_C_CONFIG" \
    bash "$TESTS_DIR/routing/sharding-3x3-smoke.sh"
}

phase_single_cluster() {
  local phase_name="$1"
  local cluster_config="$2"
  local write_count="$3"
  local binary_wallet="$4"
  local primary_wallet="$5"
  local secondary_wallet="$6"
  local smoke_wallet="$7"
  local failover_follower_wallet="$8"
  local failover_leader_wallet="$9"
  local catchup_wallet="${10}"
  local quorum_wallet="${11}"
  local phase_dir="${ARTIFACT_ROOT}/${phase_name}"

  mkdir -p "$phase_dir"
  stop_all_topologies
  run_logged "${phase_name} start" start_single_cluster "$cluster_config"
  run_logged "${phase_name} validator api smoke" run_validator_api_smoke "$cluster_config"
  run_logged "${phase_name} proposal surfaces" run_single_cluster_surfaces \
    "${phase_dir}/surfaces" "$cluster_config" "$write_count" true \
    "$primary_wallet" "$secondary_wallet" "$smoke_wallet" \
    "$failover_follower_wallet" "$failover_leader_wallet" "$catchup_wallet" "$quorum_wallet"
  if [ "$RUN_BINARY_TESTS" = "true" ]; then
    run_logged "${phase_name} binary ipfs" run_binary_upload "${phase_name}" "$cluster_config" "$binary_wallet"
  fi
  if [ "$RUN_WARM_FAILOVER" = "true" ]; then
    run_logged "${phase_name} warm failover" run_warm_failover "$cluster_config" "$WARM_FAILOVER_CYCLES"
  fi
  run_logged "${phase_name} status" run_status_cluster "$cluster_config"
}

phase_dual_cluster() {
  local phase_dir="${ARTIFACT_ROOT}/phase-03-dual-5x3"

  mkdir -p "$phase_dir"
  stop_all_topologies
  run_logged "phase-03-dual-5x3 start" start_dual_cluster
  run_logged "phase-03-dual-5x3 cluster-a validator api smoke" run_validator_api_smoke "$DUAL_CLUSTER_A_CONFIG"
  run_logged "phase-03-dual-5x3 cluster-b validator api smoke" run_validator_api_smoke "$DUAL_CLUSTER_B_CONFIG"
  run_logged "phase-03-dual-5x3 routing smoke" run_dual_cluster_routing
  run_logged "phase-03-dual-5x3 proposal surfaces" run_dual_cluster_surfaces "${phase_dir}/surfaces"
  if [ "$RUN_BINARY_TESTS" = "true" ]; then
    run_logged "phase-03-dual-5x3 binary ipfs cluster-a" run_binary_upload "phase-03-dual-5x3/cluster-a" "$DUAL_CLUSTER_A_CONFIG" "0x1100000000000000000000000000000000000000"
    run_logged "phase-03-dual-5x3 binary ipfs cluster-b" run_binary_upload "phase-03-dual-5x3/cluster-b" "$DUAL_CLUSTER_B_CONFIG" "0x8800000000000000000000000000000000000000"
  fi
  run_logged "phase-03-dual-5x3 cluster-a quorum envelope" run_quorum_envelope "$DUAL_CLUSTER_A_CONFIG" "0x5500000000000000000000000000000000000000"
  run_logged "phase-03-dual-5x3 cluster-b quorum envelope" run_quorum_envelope "$DUAL_CLUSTER_B_CONFIG" "0xaa00000000000000000000000000000000000000"
  if [ "$RUN_WARM_FAILOVER" = "true" ]; then
    run_logged "phase-03-dual-5x3 cluster-a warm failover" run_warm_failover "$DUAL_CLUSTER_A_CONFIG" "$WARM_FAILOVER_CYCLES"
    run_logged "phase-03-dual-5x3 cluster-b warm failover" run_warm_failover "$DUAL_CLUSTER_B_CONFIG" "$WARM_FAILOVER_CYCLES"
  fi
  run_logged "phase-03-dual-5x3 cluster-a status" run_status_cluster "$DUAL_CLUSTER_A_CONFIG"
  run_logged "phase-03-dual-5x3 cluster-b status" run_status_cluster "$DUAL_CLUSTER_B_CONFIG"
}

phase_triple_cluster() {
  local phase_dir="${ARTIFACT_ROOT}/phase-04-triple-5x3x3"

  mkdir -p "$phase_dir"
  stop_all_topologies
  run_logged "phase-04-triple-5x3x3 start" start_triple_cluster
  run_logged "phase-04-triple-5x3x3 cluster-a validator api smoke" run_validator_api_smoke "$FABRIC_CLUSTER_A_CONFIG"
  run_logged "phase-04-triple-5x3x3 cluster-b validator api smoke" run_validator_api_smoke "$FABRIC_CLUSTER_B_CONFIG"
  run_logged "phase-04-triple-5x3x3 cluster-c validator api smoke" run_validator_api_smoke "$FABRIC_CLUSTER_C_CONFIG"
  run_logged "phase-04-triple-5x3x3 routing smoke" run_triple_cluster_routing

  run_logged "phase-04-triple-5x3x3 cluster-a local surfaces" run_single_cluster_surfaces \
    "${phase_dir}/cluster-a-surfaces" "$FABRIC_CLUSTER_A_CONFIG" "$FABRIC_LOCAL_WRITE_COUNT_PER_ORG" false \
    "0x1100000000000000000000000000000000000000" "0x2200000000000000000000000000000000000000" "0x3300000000000000000000000000000000000000" \
    "0x1111111111111111111111111111111111111111" "0x2222222222222222222222222222222222222222" "0x4444444444444444444444444444444444444444" "0x5500000000000000000000000000000000000000"

  run_logged "phase-04-triple-5x3x3 cluster-b local surfaces" run_single_cluster_surfaces \
    "${phase_dir}/cluster-b-surfaces" "$FABRIC_CLUSTER_B_CONFIG" "$FABRIC_LOCAL_WRITE_COUNT_PER_ORG" false \
    "0x7700000000000000000000000000000000000000" "0x8800000000000000000000000000000000000000" "0x9900000000000000000000000000000000000000" \
    "0x7a00000000000000000000000000000000000000" "0x8b00000000000000000000000000000000000000" "0x9c00000000000000000000000000000000000000" "0xaa00000000000000000000000000000000000000"

  run_logged "phase-04-triple-5x3x3 cluster-c local surfaces" run_single_cluster_surfaces \
    "${phase_dir}/cluster-c-surfaces" "$FABRIC_CLUSTER_C_CONFIG" "$FABRIC_LOCAL_WRITE_COUNT_PER_ORG" false \
    "0xdd00000000000000000000000000000000000000" "0xee00000000000000000000000000000000000000" "0xff00000000000000000000000000000000000000" \
    "0xde00000000000000000000000000000000000000" "0xef00000000000000000000000000000000000000" "0xf000000000000000000000000000000000000000" "0xab00000000000000000000000000000000000000"

  if [ "$RUN_BINARY_TESTS" = "true" ]; then
    run_logged "phase-04-triple-5x3x3 binary ipfs cluster-a" run_binary_upload "phase-04-triple-5x3x3/cluster-a" "$FABRIC_CLUSTER_A_CONFIG" "0x1100000000000000000000000000000000000000"
    run_logged "phase-04-triple-5x3x3 binary ipfs cluster-b" run_binary_upload "phase-04-triple-5x3x3/cluster-b" "$FABRIC_CLUSTER_B_CONFIG" "0x7700000000000000000000000000000000000000"
    run_logged "phase-04-triple-5x3x3 binary ipfs cluster-c" run_binary_upload "phase-04-triple-5x3x3/cluster-c" "$FABRIC_CLUSTER_C_CONFIG" "0xdd00000000000000000000000000000000000000"
  fi

  run_logged "phase-04-triple-5x3x3 cluster-a quorum envelope" run_quorum_envelope "$FABRIC_CLUSTER_A_CONFIG" "0x5500000000000000000000000000000000000000"
  run_logged "phase-04-triple-5x3x3 cluster-b quorum envelope" run_quorum_envelope "$FABRIC_CLUSTER_B_CONFIG" "0xaa00000000000000000000000000000000000000"
  run_logged "phase-04-triple-5x3x3 cluster-c quorum envelope" run_quorum_envelope "$FABRIC_CLUSTER_C_CONFIG" "0xab00000000000000000000000000000000000000"

  if [ "$RUN_WARM_FAILOVER" = "true" ]; then
    run_logged "phase-04-triple-5x3x3 cluster-a warm failover" run_warm_failover "$FABRIC_CLUSTER_A_CONFIG" "$WARM_FAILOVER_CYCLES"
    run_logged "phase-04-triple-5x3x3 cluster-b warm failover" run_warm_failover "$FABRIC_CLUSTER_B_CONFIG" "$WARM_FAILOVER_CYCLES"
    run_logged "phase-04-triple-5x3x3 cluster-c warm failover" run_warm_failover "$FABRIC_CLUSTER_C_CONFIG" "$WARM_FAILOVER_CYCLES"
  fi

  run_logged "phase-04-triple-5x3x3 cluster-a status" run_status_cluster "$FABRIC_CLUSTER_A_CONFIG"
  run_logged "phase-04-triple-5x3x3 cluster-b status" run_status_cluster "$FABRIC_CLUSTER_B_CONFIG"
  run_logged "phase-04-triple-5x3x3 cluster-c status" run_status_cluster "$FABRIC_CLUSTER_C_CONFIG"
}

phase_soak() {
  if ! [[ "$SOAK_CYCLES" =~ ^[0-9]+$ ]] || [ "$SOAK_CYCLES" -le 0 ]; then
    return 0
  fi

  local cycle
  for cycle in $(seq 1 "$SOAK_CYCLES"); do
    local cycle_dir="${ARTIFACT_ROOT}/phase-05-soak/cycle-${cycle}"
    mkdir -p "$cycle_dir"
    run_logged "phase-05-soak cycle=${cycle} routing smoke" run_triple_cluster_routing
    run_logged "phase-05-soak cycle=${cycle} cluster-a local surfaces" run_single_cluster_surfaces \
      "${cycle_dir}/cluster-a-surfaces" "$FABRIC_CLUSTER_A_CONFIG" "$SOAK_WRITE_COUNT_PER_ORG" false \
      "0x1100000000000000000000000000000000000000" "0x2200000000000000000000000000000000000000" "0x3300000000000000000000000000000000000000" \
      "0x1111111111111111111111111111111111111111" "0x2222222222222222222222222222222222222222" "0x4444444444444444444444444444444444444444" "0x5500000000000000000000000000000000000000"
    run_logged "phase-05-soak cycle=${cycle} cluster-b local surfaces" run_single_cluster_surfaces \
      "${cycle_dir}/cluster-b-surfaces" "$FABRIC_CLUSTER_B_CONFIG" "$SOAK_WRITE_COUNT_PER_ORG" false \
      "0x7700000000000000000000000000000000000000" "0x8800000000000000000000000000000000000000" "0x9900000000000000000000000000000000000000" \
      "0x7a00000000000000000000000000000000000000" "0x8b00000000000000000000000000000000000000" "0x9c00000000000000000000000000000000000000" "0xaa00000000000000000000000000000000000000"
    run_logged "phase-05-soak cycle=${cycle} cluster-c local surfaces" run_single_cluster_surfaces \
      "${cycle_dir}/cluster-c-surfaces" "$FABRIC_CLUSTER_C_CONFIG" "$SOAK_WRITE_COUNT_PER_ORG" false \
      "0xdd00000000000000000000000000000000000000" "0xee00000000000000000000000000000000000000" "0xff00000000000000000000000000000000000000" \
      "0xde00000000000000000000000000000000000000" "0xef00000000000000000000000000000000000000" "0xf000000000000000000000000000000000000000" "0xab00000000000000000000000000000000000000"

    if [ "$RUN_BINARY_TESTS" = "true" ] && [ "$SOAK_BINARY_INTERVAL" -gt 0 ] && [ $((cycle % SOAK_BINARY_INTERVAL)) -eq 0 ]; then
      case $(((cycle - 1) % 3)) in
        0)
          run_logged "phase-05-soak cycle=${cycle} binary ipfs cluster-a" run_binary_upload "phase-05-soak/cluster-a" "$FABRIC_CLUSTER_A_CONFIG" "0x1100000000000000000000000000000000000000"
          ;;
        1)
          run_logged "phase-05-soak cycle=${cycle} binary ipfs cluster-b" run_binary_upload "phase-05-soak/cluster-b" "$FABRIC_CLUSTER_B_CONFIG" "0x7700000000000000000000000000000000000000"
          ;;
        2)
          run_logged "phase-05-soak cycle=${cycle} binary ipfs cluster-c" run_binary_upload "phase-05-soak/cluster-c" "$FABRIC_CLUSTER_C_CONFIG" "0xdd00000000000000000000000000000000000000"
          ;;
      esac
    fi
  done
}

log "Artifacts: ${ARTIFACT_ROOT}"
log "IPFS policy: AUTO_START_IPFS=${AUTO_START_IPFS}"

stop_all_topologies

if [ "$RUN_SINGLE_CLUSTER_3_PHASE" = "true" ]; then
  phase_single_cluster \
    "phase-01-single-cluster-3" \
    "$SINGLE_CLUSTER_3_CONFIG" \
    "$SINGLE_CLUSTER_WRITE_COUNT_PER_ORG" \
    "0x1100000000000000000000000000000000000000" \
    "0x1100000000000000000000000000000000000000" \
    "0x2200000000000000000000000000000000000000" \
    "0x3300000000000000000000000000000000000000" \
    "0x1111111111111111111111111111111111111111" \
    "0x2222222222222222222222222222222222222222" \
    "0x4444444444444444444444444444444444444444" \
    "0x5555555555555555555555555555555555555555"
fi

if [ "$RUN_SINGLE_CLUSTER_5_PHASE" = "true" ]; then
  phase_single_cluster \
    "phase-02-single-cluster-5" \
    "$SINGLE_CLUSTER_5_CONFIG" \
    "$SINGLE_CLUSTER_WRITE_COUNT_PER_ORG" \
    "0x1100000000000000000000000000000000000000" \
    "0x1100000000000000000000000000000000000000" \
    "0x2200000000000000000000000000000000000000" \
    "0x3300000000000000000000000000000000000000" \
    "0x1111111111111111111111111111111111111111" \
    "0x2222222222222222222222222222222222222222" \
    "0x4444444444444444444444444444444444444444" \
    "0x5555555555555555555555555555555555555555"
fi

if [ "$RUN_DUAL_CLUSTER_PHASE" = "true" ]; then
  phase_dual_cluster
fi

if [ "$RUN_TRIPLE_CLUSTER_PHASE" = "true" ]; then
  phase_triple_cluster
  phase_soak
fi

if [ "$STOP_AT_END" = "true" ]; then
  stop_all_topologies
fi

log "SUCCESS mock-scale-staircase completed"
log "Artifacts written to ${ARTIFACT_ROOT}"
