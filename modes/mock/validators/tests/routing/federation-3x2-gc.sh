#!/bin/bash
# Enterprise-federation 3x2 GC: member-local segment GC and binary GC on cluster B, read through A's mount.
#
# Run it after federation-3x2-smoke.sh (directory committed, B owns nsB1), with cluster B launched with
# the GC test profile and cluster A on the defaults:
#   FED_3X2_B_GC_JAVA_OPTS=test OAK_CONSENSUS_JAR=... lifecycle/start-fed-3x2.sh --fresh
# It never starts, stops or signals anything. It writes control messages, bulk messages (~3 MB) and
# validator-hosted binaries into nsB1, starts a continuous reader on cluster A (through its mount of B),
# deletes all but the control content, waits for two completed full GC runs on every B member and for
# binary GC to release the deleted binaries, then judges the reader and the convergence of both clusters.
# Expected duration: about 6-10 minutes (bounded by FED_GC_SECONDS after the deletes). Evidence:
# $FED_3X2_ROOT/evidence/gc-<UTC timestamp>/ (manifest.json, requests.ndjson, snapshots/, assertions.tsv,
# gc.json, log-scan.json, summary.json, report.md). Logic: src/federation-gc.mjs.
#
# Environment:
#   FED_3X2_ROOT                   federation root (default $HOME/oak-chain-federation/3x2)
#   OAK_CONSENSUS_JAR              the jar the clusters run (recorded with its sha256; optional here)
#   FED_JAR_SOURCE_DIR             jackrabbit-oak checkout the jar was built from (default: the jar's dir)
#   FED_SMOKE_DEADLINE_SECONDS     deadline of ordinary waits (default 60)
#   FED_SMOKE_POLL_MS              poll interval inside ordinary waits (default 2000)
#   FED_GC_SECONDS                 deadline for segment + binary GC after the last delete (default 600)
#   FED_GC_POLL_MS                 GC status poll (default 5000)
#   FED_GC_READER_MS               pause between reader rounds on A (default 2000)
#   FED_GC_BULK_WRITES             bulk messages (default 16); FED_GC_BULK_CHARS characters each (default 180000)
#   FED_GC_MAX_503_FRACTION        bound on mount 503s among A's control reads (default 0.1)
#   FED_GC_MAX_503_STREAK_SECONDS  bound on one A member's run of mount 503s (default 30)
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
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "❌ Unknown option: $1 (the GC scenario takes no arguments; see --help)"; exit 2 ;;
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
FED_SMOKE_CONFIG="$(printf '{"fedRoot":"%s","directoryFile":"%s","infraDir":"%s","lifecycleDir":"%s","configDir":"%s","command":"%s","clusters":[%s,%s]}' \
  "$FED_ROOT" "$DIRECTORY_FILE" "$REPO_ROOT" "$LIFECYCLE_DIR" "$CONFIG_DIR" "$0" "$A_JSON" "$B_JSON")"

exec node "$REPO_ROOT/src/federation-gc.mjs"
