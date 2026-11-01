#!/bin/bash
# Stop the enterprise-federation 3x2 topology, cluster B first, then cluster A. Root-bound: it
# only acts on $FED_3X2_ROOT/cluster-{a,b} through stop-cluster.sh, which signals only processes
# recorded in those roots' pid files or whose command lines name those roots' validator stores.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP_CLUSTER_SCRIPT="$SCRIPT_DIR/stop-cluster.sh"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
# shellcheck source=lib/fed-3x2.sh
source "$SCRIPT_DIR/lib/fed-3x2.sh"
FORWARD_ARGS=(--cluster-size 3)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--keep-runtime]

Stops federation cluster B, then cluster A (config/fed-3x2-cluster-{b,a}.env). A plain stop keeps
every store, Aeron log and archive, the directory file and the evidence; only start-fed-3x2.sh
--fresh resets the clusters.

  --keep-runtime  Also keep the Aeron media directories (stop-cluster.sh --keep-runtime).
EOF
}

while (($# > 0)); do
  case "$1" in
    --keep-runtime) FORWARD_ARGS+=(--keep-runtime) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

stop_named_cluster() {
  local label="$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🛑 Stopping federation cluster $label"
  echo "   config: $CONFIG_DIR/fed-3x2-cluster-$label.env"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" "$label" || exit 1
    "$STOP_CLUSTER_SCRIPT" "${FORWARD_ARGS[@]}"
  )
}

# Refuse before stopping anything if either root is unusable.
( fed_3x2_load_cluster_env "$CONFIG_DIR" a ) || exit 1
( fed_3x2_load_cluster_env "$CONFIG_DIR" b ) || exit 1

stop_named_cluster b
stop_named_cluster a
