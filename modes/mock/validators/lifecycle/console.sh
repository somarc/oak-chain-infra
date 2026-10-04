#!/bin/bash
# Interactive control console for the local mock validator cluster:
# start/stop the cluster, stop/start/kill/restart single members, and watch live status.
# A thin shim over `oak-chain mock console`; every action still runs the lifecycle scripts
# in this directory (start-cluster.sh, stop-cluster.sh, member.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/../../../../bin/oak-chain.mjs" mock console --lifecycle-dir "$SCRIPT_DIR" "$@"
