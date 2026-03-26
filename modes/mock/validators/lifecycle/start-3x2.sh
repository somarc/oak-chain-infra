#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_CLUSTER_SCRIPT="$SCRIPT_DIR/start-cluster.sh"
CONFIG_DIR="$SCRIPT_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x2-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x2-cluster-b.env}"
FORWARD_ARGS=()
WITH_MONITORS=false
BUILD_ONCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [start-cluster args...] [--cluster-a-config path] [--cluster-b-config path] [--with-monitors]

Default behavior:
  - starts cluster A and cluster B as separate 3-node Aeron clusters
  - forwards --build only to cluster A so jars are built once per 3x2 launch
  - disables watchdog/load-observer for the 3x2 topology unless --with-monitors is set
  - sources:
      * modes/mock/validators/config/mock.env
      * modes/mock/validators/config/ipfs.env
      * cluster-specific 3x2 env file
EOF
}

load_cluster_env() {
  local cluster_config="$1"
  set -a
  for cfg in "${BASE_CONFIGS[@]}" "$cluster_config"; do
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
    else
      echo "❌ Missing config file: $cfg"
      exit 1
    fi
  done
  set +a
}

cluster_aeron_range() {
  local cluster_config="$1"
  (
    load_cluster_env "$cluster_config"
    local cluster_size="${OAK_CLUSTER_SIZE:-3}"
    local start_port="${AERON_CLUSTER_BASE_PORT:-9000}"
    local end_port=$((start_port + ((cluster_size - 1) * 100) + 5))
    printf '%s|%s|%s|%s\n' \
      "${OAK_CLUSTER_NAME:-unknown}" \
      "$cluster_size" \
      "$start_port" \
      "$end_port"
  )
}

validate_no_aeron_overlap() {
  local a_name a_size a_start a_end
  local b_name b_size b_start b_end

  IFS='|' read -r a_name a_size a_start a_end < <(cluster_aeron_range "$CLUSTER_A_CONFIG")
  IFS='|' read -r b_name b_size b_start b_end < <(cluster_aeron_range "$CLUSTER_B_CONFIG")

  if [ "$a_start" -le "$b_end" ] && [ "$b_start" -le "$a_end" ]; then
    echo "❌ Aeron port overlap detected between $a_name and $b_name"
    echo "   $a_name size=$a_size range=${a_start}-${a_end}"
    echo "   $b_name size=$b_size range=${b_start}-${b_end}"
    echo "   Adjust AERON_CLUSTER_BASE_PORT values before starting a multi-cluster topology."
    exit 1
  fi
}

start_named_cluster() {
  local label="$1"
  local cluster_config="$2"
  shift 2

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🚀 Starting $label"
  echo "   config: $cluster_config"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  (
    load_cluster_env "$cluster_config"
    if [ "${#FORWARD_ARGS[@]}" -gt 0 ] || [ "$#" -gt 0 ]; then
      "$START_CLUSTER_SCRIPT" "${FORWARD_ARGS[@]}" "$@"
    else
      "$START_CLUSTER_SCRIPT"
    fi
  )
}

while (($# > 0)); do
  case "$1" in
    --cluster-a-config)
      shift
      CLUSTER_A_CONFIG="$1"
      ;;
    --cluster-b-config)
      shift
      CLUSTER_B_CONFIG="$1"
      ;;
    --with-monitors)
      WITH_MONITORS=true
      ;;
    --build)
      BUILD_ONCE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      FORWARD_ARGS+=("$1")
      ;;
  esac
  shift
done

if [ "$WITH_MONITORS" = "false" ]; then
  FORWARD_ARGS+=(--no-watchdog --no-load-observer)
fi

validate_no_aeron_overlap

if [ "$BUILD_ONCE" = "true" ]; then
  start_named_cluster "cluster-a" "$CLUSTER_A_CONFIG" --build
else
  start_named_cluster "cluster-a" "$CLUSTER_A_CONFIG"
fi
start_named_cluster "cluster-b" "$CLUSTER_B_CONFIG"

echo ""
echo "✅ 3x2 topology launch submitted."
echo "   Check status with: $SCRIPT_DIR/status-3x2.sh"
