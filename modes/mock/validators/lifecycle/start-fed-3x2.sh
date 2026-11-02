#!/bin/bash
# Start the enterprise-federation 3x2 topology: two 3-member mock clusters, one enterprise each,
# federated through a static-file directory under the federation root ($FED_3X2_ROOT, default
# $HOME/oak-chain-federation/3x2). Root-bound: it only ever acts on $FED_3X2_ROOT/cluster-a and
# $FED_3X2_ROOT/cluster-b (through start-cluster.sh) and refuses any root at or under $HOME/oak-chain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_CLUSTER_SCRIPT="$SCRIPT_DIR/start-cluster.sh"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
# shellcheck source=lib/root-guard.sh
source "$SCRIPT_DIR/lib/root-guard.sh"
# shellcheck source=lib/fed-3x2.sh
source "$SCRIPT_DIR/lib/fed-3x2.sh"

FRESH=false
FORWARD_ARGS=(--no-watchdog --no-load-observer)

usage() {
  cat <<EOF
Usage: OAK_CONSENSUS_JAR=/abs/path/oak-segment-consensus.jar $(basename "$0") [--fresh] [--wait-seconds N] [--no-caffeinate]

Starts cluster A (HTTP 8290/8292/8294, Aeron 9800, OPS proxy 8797) and cluster B (HTTP 8390/8392/8394,
Aeron 10200, OPS proxy 8798) from config/fed-3x2-*.env. Every member runs OAK_CONSENSUS_JAR; its path
and sha256 go into each cluster's launch record, so member.sh restarts the same jar.

  --fresh            Wipe both federation clusters' runtime state first (start-cluster.sh --fresh,
                     scoped to \$FED_3X2_ROOT/cluster-{a,b}) and move an existing directory file aside.
  --wait-seconds N   Readiness wait per cluster (start-cluster.sh default: 45).
  --no-caffeinate    Do not start sleep prevention.

Watchdog and load observer stay off (they write under \$HOME/oak-chain). The IPFS daemon is shared
and must already be running (AUTO_START_IPFS defaults to false here).

Environment:
  OAK_CONSENSUS_JAR  Required. Absolute path of the jar built from jackrabbit-oak feature/enterprise-federation.
  FED_3X2_ROOT       Federation root (default: \$HOME/$FED_3X2_DEFAULT_ROOT_SUFFIX). Never at or under \$HOME/oak-chain.
  FED_3X2_B_GC_JAVA_OPTS
                     Optional GC overrides for cluster B only, appended to its EXTRA_JAVA_OPTS (and so to its
                     launch record). "test" = the federation-3x2-gc.sh profile:
                     $FED_3X2_GC_TEST_JAVA_OPTS
                     Otherwise explicit -Doak.gc.<name>=<value> options. Cluster A keeps the runtime defaults.
EOF
}

while (($# > 0)); do
  case "$1" in
    --fresh) FRESH=true ;;
    --no-caffeinate) FORWARD_ARGS+=(--no-caffeinate) ;;
    --wait-seconds)
      shift
      if [ -z "${1:-}" ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "❌ --wait-seconds needs a number"
        exit 1
      fi
      FORWARD_ARGS+=(--wait-seconds "$1")
      ;;
    -h|--help) usage; exit 0 ;;
    --build) echo "❌ --build is not supported: build the federation jar yourself and pass it as OAK_CONSENSUS_JAR."; exit 1 ;;
    *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

fed_3x2_require_jar
case "$OAK_CONSENSUS_JAR" in
  *oak-segment-consensus*) ;;
  *)
    echo "⚠️  OAK_CONSENSUS_JAR does not contain 'oak-segment-consensus' in its path; stop-cluster.sh's"
    echo "   process-name fallback will not see these validators (their pid files still work)."
    ;;
esac
# One hash for both clusters: start-cluster.sh checks it and every member re-checks it at launch.
JAR_SHA256="$( (shasum -a 256 "$OAK_CONSENSUS_JAR" 2>/dev/null || sha256sum "$OAK_CONSENSUS_JAR") | awk '{print $1}')"
if [ -n "${OAK_CONSENSUS_JAR_SHA256:-}" ] && [ "$OAK_CONSENSUS_JAR_SHA256" != "$JAR_SHA256" ]; then
  echo "❌ OAK_CONSENSUS_JAR_SHA256=$OAK_CONSENSUS_JAR_SHA256 but $OAK_CONSENSUS_JAR hashes to $JAR_SHA256"
  exit 1
fi
echo "• Consensus jar: $OAK_CONSENSUS_JAR"
echo "  sha256: $JAR_SHA256"

# cluster_facts LABEL: "root|size|http_base|step|aeron_base|ops_port" after every root check passed.
cluster_facts() {
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" "$1" || exit 1
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$FED_3X2_ROOT" "$CLUSTER_RUNTIME_ROOT" "$OAK_CLUSTER_SIZE" \
      "$OAK_VALIDATOR_HTTP_BASE_PORT" "$OAK_VALIDATOR_HTTP_PORT_STEP" "$AERON_CLUSTER_BASE_PORT" "$OPS_PROXY_PORT"
  )
}

A_FACTS="$(cluster_facts a)"
B_FACTS="$(cluster_facts b)"
IFS='|' read -r FED_ROOT A_ROOT A_SIZE A_HTTP A_STEP A_AERON A_OPS <<<"$A_FACTS"
IFS='|' read -r _ B_ROOT B_SIZE B_HTTP B_STEP B_AERON B_OPS <<<"$B_FACTS"

B_GC_OPTS="$(fed_3x2_gc_java_opts "${FED_3X2_B_GC_JAVA_OPTS:-}")"
if [ -n "$B_GC_OPTS" ]; then
  echo "• Cluster B GC overrides (FED_3X2_B_GC_JAVA_OPTS): $B_GC_OPTS"
else
  echo "• Cluster B GC: runtime defaults (FED_3X2_B_GC_JAVA_OPTS unset)"
fi
echo "• Cluster A GC: runtime defaults"

a_aeron_end=$((A_AERON + (A_SIZE - 1) * 100 + 6))
b_aeron_end=$((B_AERON + (B_SIZE - 1) * 100 + 6))
if [ "$A_AERON" -le "$b_aeron_end" ] && [ "$B_AERON" -le "$a_aeron_end" ]; then
  echo "❌ Aeron port overlap: cluster A ${A_AERON}-${a_aeron_end}, cluster B ${B_AERON}-${b_aeron_end}"
  exit 1
fi

# Every port either cluster needs must be free or already held by that cluster's own processes;
# anything else (e.g. another topology on 8290) is refused before a single process is launched.
# shellcheck disable=SC2046
oak_guard_require_owned_ports "$A_ROOT" "$A_ROOT/pids" "federation cluster A start" \
  $(oak_guard_cluster_ports "$A_SIZE" "$A_HTTP" "$A_STEP" "$A_AERON") "$A_OPS"
# shellcheck disable=SC2046
oak_guard_require_owned_ports "$B_ROOT" "$B_ROOT/pids" "federation cluster B start" \
  $(oak_guard_cluster_ports "$B_SIZE" "$B_HTTP" "$B_STEP" "$B_AERON") "$B_OPS"

mkdir -p "$FED_ROOT"
DIRECTORY_FILE="$FED_ROOT/directory.json"
if [ "$FRESH" = "true" ] && [ -f "$DIRECTORY_FILE" ]; then
  aside="$DIRECTORY_FILE.$(date -u +%Y%m%dT%H%M%SZ).bak"
  echo "• --fresh: moving the previous directory file aside: $aside"
  mv "$DIRECTORY_FILE" "$aside"
fi

start_named_cluster() {
  local label="$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🚀 Starting federation cluster $label"
  echo "   config: $CONFIG_DIR/fed-3x2-cluster-$label.env"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" "$label" || exit 1
    export OAK_CONSENSUS_JAR OAK_CONSENSUS_JAR_SHA256="$JAR_SHA256"
    if [ "$FRESH" = "true" ]; then
      "$START_CLUSTER_SCRIPT" --fresh "${FORWARD_ARGS[@]}"
    else
      "$START_CLUSTER_SCRIPT" "${FORWARD_ARGS[@]}"
    fi
  )
}

start_named_cluster a
start_named_cluster b

echo ""
echo "✅ Federation 3x2 launch submitted."
echo "   root:      $FED_ROOT"
echo "   jar:       $OAK_CONSENSUS_JAR (sha256 $JAR_SHA256)"
echo "   B GC opts: ${B_GC_OPTS:-runtime defaults}"
echo "   directory: $DIRECTORY_FILE (written by tests/routing/federation-3x2-smoke.sh)"
echo "   status:    $SCRIPT_DIR/status-fed-3x2.sh"
