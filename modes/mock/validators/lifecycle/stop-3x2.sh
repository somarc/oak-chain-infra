#!/bin/bash
set -euo pipefail

# The 3x2 topology is stop-3x3.sh with the 3x2 config packs and no cluster C.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x2-cluster-a.env}" \
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x2-cluster-b.env}" \
CLUSTER_C_CONFIG="" \
  exec "$SCRIPT_DIR/stop-3x3.sh" "$@"
