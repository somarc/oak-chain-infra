#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_CLUSTER_SCRIPT="$SCRIPT_DIR/status-cluster.sh"
CONFIG_DIR="$SCRIPT_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x3-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x3-cluster-b.env}"
CLUSTER_C_CONFIG="${CLUSTER_C_CONFIG:-$CONFIG_DIR/3x3-cluster-c.env}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cluster-a-config path] [--cluster-b-config path] [--cluster-c-config path]

Shows scoped validator/IPFS/OPS status for all three local 3x3 clusters.
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

status_named_cluster() {
  local label="$1"
  local cluster_config="$2"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 Status: $label"
  echo "   config: $cluster_config"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  (
    load_cluster_env "$cluster_config"
    "$STATUS_CLUSTER_SCRIPT"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

status_named_cluster "cluster-a" "$CLUSTER_A_CONFIG"
echo ""
status_named_cluster "cluster-b" "$CLUSTER_B_CONFIG"
echo ""
status_named_cluster "cluster-c" "$CLUSTER_C_CONFIG"
