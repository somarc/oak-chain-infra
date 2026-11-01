#!/bin/bash
# Enterprise-federation 3x2 live smoke.
#
# Assumes both federation clusters are already running (lifecycle/start-fed-3x2.sh) and never
# starts, stops or signals anything. It writes the shared directory file, sends fewer than 30
# signed writes/deletes, and leaves one immutable evidence directory under
# $FED_3X2_ROOT/evidence/<UTC timestamp>/ (manifest.json, requests.ndjson, per-phase snapshots,
# assertions.tsv, log-scan.json, summary.json, report.md). The logic lives in
# src/federation-smoke.mjs; this script only resolves the topology from config/fed-3x2-*.env.
#
# Environment:
#   FED_3X2_ROOT                 federation root (default $HOME/oak-chain-federation/3x2)
#   OAK_CONSENSUS_JAR            the jar the clusters run (recorded with its sha256; optional here)
#   FED_JAR_SOURCE_DIR           jackrabbit-oak checkout the jar was built from (default: the jar's dir)
#   FED_SMOKE_DEADLINE_SECONDS   deadline of every wait (default 60)
#   FED_SMOKE_POLL_MS            poll interval inside waits (default 2000)
#
# Exit: 0 PASS, 1 FAIL (or aborted), 2 refused before any action.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$(cd "$TESTS_DIR/../config" && pwd)"
LIFECYCLE_DIR="$(cd "$TESTS_DIR/../lifecycle" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../../.." && pwd)"
# shellcheck source=../../lifecycle/lib/fed-3x2.sh
source "$LIFECYCLE_DIR/lib/fed-3x2.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "❌ Unknown option: $1 (the smoke takes no arguments; see --help)"; exit 2 ;;
esac

# cluster_json LABEL: the cluster's resolved topology as one JSON object (values have no quotes).
cluster_json() {
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" "$1" || exit 1
    printf '{"label":"%s","name":"%s","enterpriseId":"%s","runtimeRoot":"%s","pidDir":"%s","logDir":"%s","httpBase":%s,"httpStep":%s,"size":%s,"aeronBase":%s,"opsPort":%s}' \
      "$1" "$OAK_CLUSTER_NAME" "$FED_3X2_ENTERPRISE_ID" "$CLUSTER_RUNTIME_ROOT" "$PID_DIR" "$LOG_DIR" \
      "$OAK_VALIDATOR_HTTP_BASE_PORT" "$OAK_VALIDATOR_HTTP_PORT_STEP" "$OAK_CLUSTER_SIZE" "$AERON_CLUSTER_BASE_PORT" "$OPS_PROXY_PORT"
  )
}

fed_facts() {
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" a || exit 1
    printf '%s|%s\n' "$FED_3X2_ROOT" "$FED_3X2_DIRECTORY_FILE"
  )
}

if ! FACTS="$(fed_facts)" || ! A_JSON="$(cluster_json a)" || ! B_JSON="$(cluster_json b)"; then
  exit 2
fi
IFS='|' read -r FED_ROOT DIRECTORY_FILE <<<"$FACTS"

if [ ! -d "$FED_ROOT" ]; then
  echo "❌ Federation root $FED_ROOT does not exist: start the clusters first (lifecycle/start-fed-3x2.sh)."
  exit 2
fi

export FED_SMOKE_CONFIG
FED_SMOKE_CONFIG="$(printf '{"fedRoot":"%s","directoryFile":"%s","infraDir":"%s","command":"%s","clusters":[%s,%s]}' \
  "$FED_ROOT" "$DIRECTORY_FILE" "$REPO_ROOT" "$0" "$A_JSON" "$B_JSON")"

exec node "$REPO_ROOT/src/federation-smoke.mjs"
