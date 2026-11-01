#!/bin/bash
# Read-only status of the enterprise-federation 3x2 topology: per-cluster validator/IPFS/OPS status
# (status-cluster.sh), the launch record's consensus jar, and each member's federation view.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_CLUSTER_SCRIPT="$SCRIPT_DIR/status-cluster.sh"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
# shellcheck source=lib/fed-3x2.sh
source "$SCRIPT_DIR/lib/fed-3x2.sh"
# shellcheck source=lib/launch-record.sh
source "$SCRIPT_DIR/lib/launch-record.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Shows both federation clusters (config/fed-3x2-cluster-{a,b}.env): process/HTTP status, the jar in
each launch record, and per member GET /v1/federation (charter digest, cluster id, directory epoch
and digest, lastAction, sourceError). Read-only.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "❌ Unknown option: $1"; usage; exit 1 ;;
esac

# One line per member from GET /v1/federation.
federation_line() {
  local port="$1"
  curl -s --max-time 3 "http://127.0.0.1:$port/v1/federation" 2>/dev/null | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  const short = (v) => (typeof v === "string" && v.length > 14 ? `${v.slice(0, 10)}…` : (v ?? "-"));
  try {
    const f = JSON.parse(raw);
    const s = f.status ?? {};
    console.log(`federation:${process.argv[1]} charter=${short(f.charterDigest)} cluster=${short(f.clusterId)}`
      + ` matches=${s.charterMatchesConfig ?? "-"} federated=${s.federated ?? "-"} epoch=${s.directoryEpoch ?? "-"}`
      + ` directory=${short(f.directoryDigest)} local=${s.localStatus ?? "-"} last=${s.lastAction ?? "-"}`
      + ` sourceError=${s.sourceError ?? "-"}`);
  } catch {
    console.log(`federation:${process.argv[1]} unavailable`);
  }
});' "$port"
}

status_named_cluster() {
  local label="$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 Status: federation cluster $label"
  echo "   config: $CONFIG_DIR/fed-3x2-cluster-$label.env"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  (
    fed_3x2_load_cluster_env "$CONFIG_DIR" "$label" || exit 1
    "$STATUS_CLUSTER_SCRIPT" || true
    record="$PID_DIR/cluster-launch.env"
    echo "consensus-jar:$(oak_launch_record_get "$record" OAK_CONSENSUS_JAR || echo '-') sha256=$(oak_launch_record_get "$record" OAK_CONSENSUS_JAR_SHA256 || echo '-')"
    for node in 0 1 2; do
      federation_line $((OAK_VALIDATOR_HTTP_BASE_PORT + node * OAK_VALIDATOR_HTTP_PORT_STEP))
    done
  )
}

status_named_cluster a
echo ""
status_named_cluster b
