#!/bin/bash
# Run a single oak-segment-consensus validator node locally
# Usage: ./run-validator-node.sh <node-id>
# Example: ./run-validator-node.sh 0

set -e

# Get script directory and find workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_workspace_root() {
    if [ -n "${OAK_ROOT:-}" ] && [ -d "${OAK_ROOT}/jackrabbit-oak" ]; then
        echo "$OAK_ROOT"
        return
    fi
    local cursor="$SCRIPT_DIR"
    while [ "$cursor" != "/" ]; do
        if [ -d "$cursor/jackrabbit-oak" ]; then
            echo "$cursor"
            return
        fi
        cursor="$(dirname "$cursor")"
    done
    echo ""
}

WORKSPACE_ROOT="$(detect_workspace_root)"
if [ -z "$WORKSPACE_ROOT" ]; then
    echo "❌ ERROR: Could not locate OAK workspace root (missing jackrabbit-oak)."
    echo "   Set OAK_ROOT explicitly and retry."
    exit 1
fi

# Load environment variables from .env.local if it exists (for API keys, etc.)
if [ -f "$WORKSPACE_ROOT/.env.local" ]; then
    echo "🔐 Loading environment variables from .env.local"
    set -a  # Auto-export all variables
    source "$WORKSPACE_ROOT/.env.local"
    set +a  # Disable auto-export
fi

# Detect Oak version from pom.xml (dynamic)
get_oak_version() {
    local pom_file="$WORKSPACE_ROOT/jackrabbit-oak/oak-parent/pom.xml"
    if [ -f "$pom_file" ]; then
        grep -m1 '<version>.*SNAPSHOT</version>' "$pom_file" | sed 's/.*<version>\(.*\)<\/version>.*/\1/' | tr -d ' '
    else
        echo "1.91-SNAPSHOT"
    fi
}
OAK_VERSION="${OAK_VERSION:-$(get_oak_version)}"
echo "📦 Oak version: $OAK_VERSION"

# Find consensus JAR file (try multiple possible locations and names)
JAR_FILE=""
# Try standard name first (shade plugin renames to oak-segment-consensus.jar)
if [ -f "$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
# Try standalone variant with version
elif [ -f "$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar" ]; then
    JAR_FILE="$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar"
elif [ -f "$SCRIPT_DIR/../../../jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
elif [ -f "$SCRIPT_DIR/../../../jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar" ]; then
    JAR_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar"
elif [ -f "jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$(pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
elif [ -f "jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar" ]; then
    JAR_FILE="$(pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar"
else
    echo "❌ ERROR: Cannot find oak-segment-consensus.jar"
    echo "   Tried:"
    echo "     - $WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
    echo "     - $WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus-${OAK_VERSION}-standalone.jar"
    echo "     - $(pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
    exit 1
fi

# Find agentic JAR file (try multiple possible locations)
AGENTIC_JAR_FILE=""
if [ -f "$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar" ]; then
    AGENTIC_JAR_FILE="$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar"
elif [ -f "$SCRIPT_DIR/../../../jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar" ]; then
    AGENTIC_JAR_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar"
elif [ -f "jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar" ]; then
    AGENTIC_JAR_FILE="$(pwd)/jackrabbit-oak/oak-segment-agentic/target/oak-segment-agentic-${OAK_VERSION}.jar"
fi

NODE_ID=${1:-0}
AERON_CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
if [ "$AERON_CLUSTER_SIZE" != "3" ] && [ "$AERON_CLUSTER_SIZE" != "5" ]; then
    echo "⚠️  Invalid OAK_CLUSTER_SIZE=$AERON_CLUSTER_SIZE, defaulting to 3"
    AERON_CLUSTER_SIZE="3"
fi
CLUSTER_NAME="${OAK_CLUSTER_NAME:-single-cluster}"
VALIDATOR_HOST="${OAK_VALIDATOR_HOST:-localhost}"
HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
EXTRA_JAVA_OPTS="${EXTRA_JAVA_OPTS:-}"

# Ports: default 8090, 8092, 8094 for the legacy single-cluster flow.
HTTP_PORT=$((HTTP_BASE_PORT + (NODE_ID * HTTP_PORT_STEP)))

# Store directory for this node
STORE_DIR="$CLUSTER_RUNTIME_ROOT/validator-$NODE_ID"

# Create store directory
mkdir -p "$STORE_DIR"

resolve_aeron_dir_base() {
    if [ -n "${AERON_DIR_BASE:-}" ]; then
        echo "${AERON_DIR_BASE%/}"
        return
    fi
    if [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
        echo "${AERON_RAMDISK_ROOT%/}/${CLUSTER_NAME}/aeron-media"
        return
    fi
    echo "$STORE_DIR/aeron-media"
}

# Log directory
LOG_DIR="${LOG_DIR:-$CLUSTER_RUNTIME_ROOT/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/validator-$NODE_ID.log"

# Aeron cluster configuration
CLUSTER_BASE_PORT="${AERON_CLUSTER_BASE_PORT:-9000}"
AERON_DIR_BASE="$(resolve_aeron_dir_base)"
AERON_DIR="${AERON_DIR:-${AERON_DIR_BASE}-${NODE_ID}-driver}"
BLOBSTORE_TYPE="${BLOBSTORE_TYPE:-ipfs}"
IPFS_API_ENDPOINT="${IPFS_API_ENDPOINT:-/ip4/127.0.0.1/tcp/5001}"
IPFS_GATEWAY_BASE="${IPFS_GATEWAY_BASE:-http://127.0.0.1:8099/ipfs/}"
IPFS_LOCAL_GATEWAY_BASE="${IPFS_LOCAL_GATEWAY_BASE:-http://127.0.0.1:8099/ipfs/}"
HEALTH_PEER_PROBE_MODE="${OAK_HEALTH_PEER_PROBE_MODE:-http}"
AERON_SOCKET_SNDBUF="${AERON_SOCKET_SNDBUF:-16384}"
AERON_SOCKET_RCVBUF="${AERON_SOCKET_RCVBUF:-16384}"
AERON_RCV_INITIAL_WINDOW="${AERON_RCV_INITIAL_WINDOW:-16384}"
MOCK_EPOCH_DURATION_SECONDS="${OAK_MOCK_EPOCH_DURATION_SECONDS:-300}"
PROPOSAL_BATCH_MAX="${OAK_PROPOSAL_BATCH_MAX:-25}"
PROPOSAL_FINALIZATION_CHUNK_SIZE="${OAK_PROPOSAL_FINALIZATION_CHUNK_SIZE:-25}"
PROPOSAL_FINALIZATION_CHUNK_DELAY_MS="${OAK_PROPOSAL_FINALIZATION_CHUNK_DELAY_MS:-0}"
CONSENSUS_MAX_PENDING_MESSAGES="${OAK_CONSENSUS_MAX_PENDING_MESSAGES:-10000}"
CONSENSUS_BACKPRESSURE_TIMEOUT_MS="${OAK_CONSENSUS_BACKPRESSURE_TIMEOUT_MS:-30000}"
OAK_CLUSTER_MAX_CONCURRENT_SESSIONS="${OAK_CLUSTER_MAX_CONCURRENT_SESSIONS:-32}"
PROPOSAL_PERSISTENCE_ENABLED="${OAK_PROPOSAL_PERSISTENCE_ENABLED:-true}"
PROPOSAL_PERSISTENCE_FLUSH_MS="${OAK_PROPOSAL_PERSISTENCE_FLUSH_MS:-1000}"
PROPOSAL_PERSISTENCE_FLUSH_BATCH="${OAK_PROPOSAL_PERSISTENCE_FLUSH_BATCH:-500}"
QUEUE_TUNING_SYSTEM_PROP_FALLBACK="${OAK_QUEUE_TUNING_SYSTEM_PROP_FALLBACK:-true}"
mkdir -p "$(dirname "$AERON_DIR_BASE")"

write_queue_tuning_osgi_cfg() {
    local store_dir="$1"
    local config_dir="$store_dir/config"
    local cfg_path="$config_dir/org.apache.jackrabbit.oak.segment.consensus.queue.ProposalQueueTuningService.cfg"

    mkdir -p "$config_dir"
    cat > "$cfg_path" <<EOF
confirmation_timeout_ms=300000
restore_timeout_ms=300000
max_message_batch=${PROPOSAL_BATCH_MAX}
max_retry_count=5
finalization_chunk_size=${PROPOSAL_FINALIZATION_CHUNK_SIZE}
finalization_chunk_delay_ms=${PROPOSAL_FINALIZATION_CHUNK_DELAY_MS}
verifier_threads=1
processed_retention_ms=600000
persistence_enabled=${PROPOSAL_PERSISTENCE_ENABLED}
persistence_flush_interval_ms=${PROPOSAL_PERSISTENCE_FLUSH_MS}
persistence_flush_batch=${PROPOSAL_PERSISTENCE_FLUSH_BATCH}
max_pending_messages=${CONSENSUS_MAX_PENDING_MESSAGES}
backpressure_timeout_ms=${CONSENSUS_BACKPRESSURE_TIMEOUT_MS}
backpressure_park_nanos=1000000
EOF
    echo "$cfg_path"
}

ipfs_api_http_from_endpoint() {
    local endpoint="$1"
    if [[ "$endpoint" =~ ^https?:// ]]; then
        echo "$endpoint"
        return 0
    fi
    if [[ "$endpoint" =~ ^/ip4/([^/]+)/tcp/([0-9]+)$ ]]; then
        echo "http://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

ipfs_api_is_ready() {
    local base="$1"
    curl -sS -X POST --max-time 2 "$base/api/v0/version" >/dev/null 2>&1 || \
        curl -sS -X POST --max-time 2 "$base/api/v0/id" >/dev/null 2>&1
}

ensure_ipfs_ready_for_blobstore() {
    [ "$BLOBSTORE_TYPE" = "ipfs" ] || return 0

    local primary=""
    local fallback=""
    if primary="$(ipfs_api_http_from_endpoint "$IPFS_API_ENDPOINT")"; then
        :
    else
        primary="http://127.0.0.1:5001"
    fi

    if [ "$primary" = "http://127.0.0.1:5001" ]; then
        fallback="http://localhost:5001"
    elif [ "$primary" = "http://localhost:5001" ]; then
        fallback="http://127.0.0.1:5001"
    fi

    if ipfs_api_is_ready "$primary"; then
        return 0
    fi
    if [ -n "$fallback" ] && ipfs_api_is_ready "$fallback"; then
        return 0
    fi

    echo "❌ ERROR: IPFS API unavailable for blobstore startup"
    echo "   endpoint: $IPFS_API_ENDPOINT"
    echo "   checked:  $primary${fallback:+ and $fallback}"
    echo "   Fix: start IPFS daemon before launching validator"
    echo "   cmd: ipfs daemon"
    return 1
}

# Build list of peer URLs from cluster size and node id
if [ "$NODE_ID" -ge "$AERON_CLUSTER_SIZE" ]; then
    echo "❌ ERROR: node-id $NODE_ID is out of range for OAK_CLUSTER_SIZE=$AERON_CLUSTER_SIZE"
    exit 1
fi

PEERS=""
for i in $(seq 0 $((AERON_CLUSTER_SIZE - 1))); do
    if [ "$i" -eq "$NODE_ID" ]; then
        continue
    fi
    peer_port=$((HTTP_BASE_PORT + (i * HTTP_PORT_STEP)))
    if [ -z "$PEERS" ]; then
        PEERS="http://$VALIDATOR_HOST:$peer_port"
    else
        PEERS="$PEERS,http://$VALIDATOR_HOST:$peer_port"
    fi
done

HOSTNAMES=""
for i in $(seq 1 "$AERON_CLUSTER_SIZE"); do
    if [ -z "$HOSTNAMES" ]; then
        HOSTNAMES="$VALIDATOR_HOST"
    else
        HOSTNAMES="$HOSTNAMES,$VALIDATOR_HOST"
    fi
done

# Get JAR file modification times
get_jar_timestamp() {
    local jar_path="$1"
    if [ ! -f "$jar_path" ]; then
        echo ""
        return
    fi
    
    # macOS/BSD stat format
    if stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$jar_path" >/dev/null 2>&1; then
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$jar_path"
    # Linux/GNU stat format (fallback)
    elif stat -c "%y" "$jar_path" >/dev/null 2>&1; then
        stat -c "%y" "$jar_path" | cut -d'.' -f1
    else
        ls -lh "$jar_path" | awk '{print $6, $7, $8}'
    fi
}

JAR_MODIFIED=$(get_jar_timestamp "$JAR_FILE")
AGENTIC_JAR_MODIFIED=$(get_jar_timestamp "$AGENTIC_JAR_FILE")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Starting Validator Node $NODE_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster Name: $CLUSTER_NAME"
echo "HTTP Port: $HTTP_PORT"
echo "HTTP Base Port: $HTTP_BASE_PORT"
echo "Store Dir: $STORE_DIR"
echo "Aeron Dir: $AERON_DIR"
if [ -n "${AERON_RAMDISK_ROOT:-}" ]; then
    echo "Aeron Storage: ramdisk root=${AERON_RAMDISK_ROOT}"
else
    echo "Aeron Storage: disk"
fi
echo "Peers: $PEERS"
echo "Cluster Size: $AERON_CLUSTER_SIZE"
echo "Aeron Base Port: $CLUSTER_BASE_PORT"
echo "Mock Epoch Duration: ${MOCK_EPOCH_DURATION_SECONDS}s"
echo "Log File: $LOG_FILE"
echo "Queue Tuning (target): persistence.enabled=$PROPOSAL_PERSISTENCE_ENABLED, flush.ms=$PROPOSAL_PERSISTENCE_FLUSH_MS, flush.batch=$PROPOSAL_PERSISTENCE_FLUSH_BATCH, batch.max=$PROPOSAL_BATCH_MAX, finalization.chunk.size=$PROPOSAL_FINALIZATION_CHUNK_SIZE, finalization.chunk.delay.ms=$PROPOSAL_FINALIZATION_CHUNK_DELAY_MS, max.pending.messages=$CONSENSUS_MAX_PENDING_MESSAGES, backpressure.timeout.ms=$CONSENSUS_BACKPRESSURE_TIMEOUT_MS"
echo "Aeron Max Concurrent Sessions: $OAK_CLUSTER_MAX_CONCURRENT_SESSIONS"
echo "Queue Tuning JVM fallback: $QUEUE_TUNING_SYSTEM_PROP_FALLBACK"
echo "Peer Probe Mode: $HEALTH_PEER_PROBE_MODE"
if [ -n "$EXTRA_JAVA_OPTS" ]; then
    echo "Extra JVM Opts: $EXTRA_JAVA_OPTS"
fi
echo ""
echo "📦 JAR Files:"
echo "  Consensus JAR: $JAR_FILE"
if [ -n "$JAR_MODIFIED" ]; then
    echo "  Consensus JAR Modified: $JAR_MODIFIED"
fi
if [ -n "$AGENTIC_JAR_FILE" ]; then
    echo "  Agentic JAR: $AGENTIC_JAR_FILE"
    if [ -n "$AGENTIC_JAR_MODIFIED" ]; then
        echo "  Agentic JAR Modified: $AGENTIC_JAR_MODIFIED"
    fi
else
    echo "  Agentic JAR: ⚠️  Not found (may be bundled in consensus JAR)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! ensure_ipfs_ready_for_blobstore; then
    exit 1
fi

QUEUE_TUNING_CFG_PATH="$(write_queue_tuning_osgi_cfg "$STORE_DIR")"
echo "Queue Tuning OSGi cfg: $QUEUE_TUNING_CFG_PATH"

queue_tuning_jvm_args=""
if [ "$QUEUE_TUNING_SYSTEM_PROP_FALLBACK" = "true" ]; then
    queue_tuning_jvm_args="-Doak.proposal.persistence.enabled=$PROPOSAL_PERSISTENCE_ENABLED -Doak.proposal.persistence.flush.ms=$PROPOSAL_PERSISTENCE_FLUSH_MS -Doak.proposal.persistence.flush.batch=$PROPOSAL_PERSISTENCE_FLUSH_BATCH -Doak.proposal.batch.max=$PROPOSAL_BATCH_MAX -Doak.proposal.finalization.chunk.size=$PROPOSAL_FINALIZATION_CHUNK_SIZE -Doak.proposal.finalization.chunk.delay.ms=$PROPOSAL_FINALIZATION_CHUNK_DELAY_MS -Doak.consensus.max.pending.messages=$CONSENSUS_MAX_PENDING_MESSAGES -Doak.consensus.backpressure.timeout.ms=$CONSENSUS_BACKPRESSURE_TIMEOUT_MS"
fi

aeron_session_jvm_args=""
if [ "${OAK_CLUSTER_MAX_CONCURRENT_SESSIONS:-0}" -gt 0 ] 2>/dev/null; then
    aeron_session_jvm_args="-Doak.cluster.max.concurrent.sessions=$OAK_CLUSTER_MAX_CONCURRENT_SESSIONS"
fi

# Run the validator, redirecting output to log file
# Aeron Cluster requires access to internal Java APIs for Agrona Unsafe access
exec java \
  --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED \
  -Dconsensus.enabled=true \
  -Dconsensus.mode=aeron \
  -Dconsensus.self.url="http://$VALIDATOR_HOST:$HTTP_PORT" \
  -Dconsensus.peers="$PEERS" \
  -Daeron.cluster.nodeId=$NODE_ID \
  -Daeron.cluster.hostnames="$HOSTNAMES" \
  -Daeron.cluster.basePort=$CLUSTER_BASE_PORT \
  -Daeron.dir="$AERON_DIR_BASE" \
  -Daeron.dir.name="$AERON_DIR" \
  -Daeron.cluster.bootstrap=false \
  -Daeron.socket.so_sndbuf="$AERON_SOCKET_SNDBUF" \
  -Daeron.socket.so_rcvbuf="$AERON_SOCKET_RCVBUF" \
  -Daeron.rcv.initial.window.length="$AERON_RCV_INITIAL_WINDOW" \
  -Doak.mock.epoch.duration.seconds="$MOCK_EPOCH_DURATION_SECONDS" \
  -Dwallet.keystore.path="$STORE_DIR/validator-keystore.properties" \
  -Dblobstore.type="$BLOBSTORE_TYPE" \
  -Dipfs.api.endpoint="$IPFS_API_ENDPOINT" \
  -Dipfs.gateway.base="$IPFS_GATEWAY_BASE" \
  -Dipfs.local.gateway.base="$IPFS_LOCAL_GATEWAY_BASE" \
  -Doak.health.peerProbeMode="$HEALTH_PEER_PROBE_MODE" \
  $queue_tuning_jvm_args \
  $aeron_session_jvm_args \
  $EXTRA_JAVA_OPTS \
  ${BEACON_API_KEY:+-Dbeacon.api.key="$BEACON_API_KEY"} \
  ${BEACON_API_URL:+-Dbeacon.api.url="$BEACON_API_URL"} \
  -jar "$JAR_FILE" \
  --port $HTTP_PORT \
  --store "$STORE_DIR" \
  >> "$LOG_FILE" 2>&1
