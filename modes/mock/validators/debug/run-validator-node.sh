#!/bin/bash
# Run a single oak-segment-consensus validator node locally
# Usage: ./run-validator-node.sh <node-id>
# Example: ./run-validator-node.sh 0

set -e

# Get script directory and find workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go up 4 levels: debug/ -> local-development/ -> scripts/ -> blockchain-aem-infra/ -> OAK/
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

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

# Ports: 8091, 8092, 8093
BASE_PORT=8091
HTTP_PORT=$((BASE_PORT + NODE_ID))

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

# Build list of peer URLs (all on localhost with different ports)
# For dynamic joining: new validators should include all existing validators
PEERS=""
if [ $NODE_ID -eq 0 ]; then
    # Node 0: peers with 1 and 2 (initial cluster)
    PEERS="http://localhost:8092,http://localhost:8093"
elif [ $NODE_ID -eq 1 ]; then
    # Node 1: peers with 0 and 2 (initial cluster)
    PEERS="http://localhost:8091,http://localhost:8093"
elif [ $NODE_ID -eq 2 ]; then
    # Node 2: peers with 0 and 1 (initial cluster)
    PEERS="http://localhost:8091,http://localhost:8092"
elif [ $NODE_ID -eq 3 ]; then
    # Node 3: joins later, peers with all existing validators (0, 1, 2)
    PEERS="http://localhost:8091,http://localhost:8092,http://localhost:8093"
elif [ $NODE_ID -eq 4 ]; then
    # Node 4: joins later, peers with all existing validators (0, 1, 2, 3)
    PEERS="http://localhost:8091,http://localhost:8092,http://localhost:8093,http://localhost:8094"
else
    echo "⚠️  Warning: Node ID $NODE_ID not configured, using default peers"
    PEERS="http://localhost:8091,http://localhost:8092,http://localhost:8093"
fi

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
  -Daeron.cluster.hostnames="localhost,localhost,localhost,localhost,localhost" \
  -Daeron.cluster.basePort=$CLUSTER_BASE_PORT \
  -Daeron.cluster.bootstrap=false \
  -Dwallet.keystore.path="$STORE_DIR/validator-keystore.properties" \
  ${BEACON_API_KEY:+-Dbeacon.api.key="$BEACON_API_KEY"} \
  ${BEACON_API_URL:+-Dbeacon.api.url="$BEACON_API_URL"} \
  -jar "$JAR_FILE" \
  --port $HTTP_PORT \
  --store "$STORE_DIR" \
  >> "$LOG_FILE" 2>&1

