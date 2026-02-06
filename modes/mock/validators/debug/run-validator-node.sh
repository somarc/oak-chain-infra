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

# Ports: 8090, 8092, 8094 (local mock cluster)
if [ "$NODE_ID" -eq 0 ]; then
    HTTP_PORT=8090
elif [ "$NODE_ID" -eq 1 ]; then
    HTTP_PORT=8092
elif [ "$NODE_ID" -eq 2 ]; then
    HTTP_PORT=8094
elif [ "$NODE_ID" -eq 3 ]; then
    HTTP_PORT=8096
elif [ "$NODE_ID" -eq 4 ]; then
    HTTP_PORT=8098
else
    HTTP_PORT=$((8090 + (NODE_ID * 2)))
fi

# Store directory for this node
STORE_DIR="$HOME/oak-chain/validator-$NODE_ID"

# Create store directory
mkdir -p "$STORE_DIR"

# Log directory
LOG_DIR="$HOME/oak-chain/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/validator-$NODE_ID.log"

# Aeron cluster configuration
CLUSTER_BASE_PORT=9000
AERON_DIR="$HOME/oak-chain/aeron-$NODE_ID"
BLOBSTORE_TYPE="${BLOBSTORE_TYPE:-ipfs}"
IPFS_API_ENDPOINT="${IPFS_API_ENDPOINT:-/ip4/127.0.0.1/tcp/5001}"
AERON_SOCKET_SNDBUF="${AERON_SOCKET_SNDBUF:-16384}"
AERON_SOCKET_RCVBUF="${AERON_SOCKET_RCVBUF:-16384}"
AERON_RCV_INITIAL_WINDOW="${AERON_RCV_INITIAL_WINDOW:-16384}"

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
    peer_port=$((8090 + (i * 2)))
    if [ -z "$PEERS" ]; then
        PEERS="http://localhost:$peer_port"
    else
        PEERS="$PEERS,http://localhost:$peer_port"
    fi
done

HOSTNAMES=""
for i in $(seq 1 "$AERON_CLUSTER_SIZE"); do
    if [ -z "$HOSTNAMES" ]; then
        HOSTNAMES="localhost"
    else
        HOSTNAMES="$HOSTNAMES,localhost"
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
echo "HTTP Port: $HTTP_PORT"
echo "Store Dir: $STORE_DIR"
echo "Aeron Dir: $AERON_DIR"
echo "Peers: $PEERS"
echo "Cluster Size: $AERON_CLUSTER_SIZE"
echo "Log File: $LOG_FILE"
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

# Run the validator, redirecting output to log file
# Aeron Cluster requires access to internal Java APIs for Agrona Unsafe access
java \
  --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED \
  -Dconsensus.enabled=true \
  -Dconsensus.mode=aeron \
  -Dconsensus.self.url="http://localhost:$HTTP_PORT" \
  -Dconsensus.peers="$PEERS" \
  -Daeron.cluster.nodeId=$NODE_ID \
  -Daeron.cluster.hostnames="$HOSTNAMES" \
  -Daeron.cluster.basePort=$CLUSTER_BASE_PORT \
  -Daeron.cluster.bootstrap=false \
  -Daeron.socket.so_sndbuf="$AERON_SOCKET_SNDBUF" \
  -Daeron.socket.so_rcvbuf="$AERON_SOCKET_RCVBUF" \
  -Daeron.rcv.initial.window.length="$AERON_RCV_INITIAL_WINDOW" \
  -Dwallet.keystore.path="$STORE_DIR/validator-keystore.properties" \
  -Dblobstore.type="$BLOBSTORE_TYPE" \
  -Dipfs.api.endpoint="$IPFS_API_ENDPOINT" \
  ${BEACON_API_KEY:+-Dbeacon.api.key="$BEACON_API_KEY"} \
  ${BEACON_API_URL:+-Dbeacon.api.url="$BEACON_API_URL"} \
  -jar "$JAR_FILE" \
  --port $HTTP_PORT \
  --store "$STORE_DIR" \
  >> "$LOG_FILE" 2>&1
