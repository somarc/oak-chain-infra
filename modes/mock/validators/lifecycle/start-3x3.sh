#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_CLUSTER_SCRIPT="$SCRIPT_DIR/start-cluster.sh"
CONFIG_DIR="$SCRIPT_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x3-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x3-cluster-b.env}"
CLUSTER_C_CONFIG="${CLUSTER_C_CONFIG:-$CONFIG_DIR/3x3-cluster-c.env}"
FORWARD_ARGS=()
WITH_MONITORS=false
BUILD_ONCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [start-cluster args...] [--cluster-a-config path] [--cluster-b-config path] [--cluster-c-config path] [--with-monitors]

Default behavior:
  - starts clusters A, B, and C as separate 3-node Aeron clusters
  - forwards --build only to cluster A so jars are built once per 3x3 launch
  - disables watchdog/load-observer for the 3x3 topology unless --with-monitors is set
  - sources:
      * modes/mock/validators/config/mock.env
      * modes/mock/validators/config/ipfs.env
      * cluster-specific 3x3 env file
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
    --cluster-c-config)
      shift
      CLUSTER_C_CONFIG="$1"
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

if [ "$BUILD_ONCE" = "true" ]; then
  start_named_cluster "cluster-a" "$CLUSTER_A_CONFIG" --build
else
  start_named_cluster "cluster-a" "$CLUSTER_A_CONFIG"
fi
start_named_cluster "cluster-b" "$CLUSTER_B_CONFIG"
start_named_cluster "cluster-c" "$CLUSTER_C_CONFIG"

echo ""
echo "✅ 3x3 topology launch submitted."
echo "   Check status with: $SCRIPT_DIR/status-3x3.sh"
