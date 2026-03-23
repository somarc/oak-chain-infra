#!/bin/bash
# Run a single oak-segment-consensus validator node locally WITH DEBUG ENABLED
# Usage: ./run-validator-node-debug.sh <node-id> [debug-port]
# Example: ./run-validator-node-debug.sh 0 5005
#          ./run-validator-node-debug.sh 1 5006
#          ./run-validator-node-debug.sh 2 5007

set -e

# Get script directory and find workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go up 4 levels: debug/ -> local-development/ -> scripts/ -> blockchain-aem-infra/ -> OAK/
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Find JAR file (try multiple possible locations)
JAR_FILE=""
if [ -f "$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
elif [ -f "$SCRIPT_DIR/../../../jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
elif [ -f "jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar" ]; then
    JAR_FILE="$(pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
else
    echo "❌ ERROR: Cannot find oak-segment-consensus.jar"
    echo "   Tried:"
    echo "     - $WORKSPACE_ROOT/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
    echo "     - $(pwd)/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar"
    exit 1
fi

NODE_ID=${1:-0}
DEBUG_PORT=${2:-$((5005 + NODE_ID))}

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
PEERS=""
if [ $NODE_ID -eq 0 ]; then
    PEERS="http://localhost:8092,http://localhost:8093"
elif [ $NODE_ID -eq 1 ]; then
    PEERS="http://localhost:8091,http://localhost:8093"
elif [ $NODE_ID -eq 2 ]; then
    PEERS="http://localhost:8091,http://localhost:8092"
fi

# Get JAR file modification time
JAR_MODIFIED=""
if [ -f "$JAR_FILE" ]; then
    # macOS/BSD stat format
    if stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$JAR_FILE" >/dev/null 2>&1; then
        JAR_MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$JAR_FILE")
    # Linux/GNU stat format (fallback)
    elif stat -c "%y" "$JAR_FILE" >/dev/null 2>&1; then
        JAR_MODIFIED=$(stat -c "%y" "$JAR_FILE" | cut -d'.' -f1)
    else
        JAR_MODIFIED=$(ls -lh "$JAR_FILE" | awk '{print $6, $7, $8}')
    fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🐛 Starting Validator Node $NODE_ID (DEBUG MODE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "HTTP Port: $HTTP_PORT"
echo "Debug Port: $DEBUG_PORT"
echo "Store Dir: $STORE_DIR"
echo "Aeron Dir: $AERON_DIR"
echo "Peers: $PEERS"
echo "Log File: $LOG_FILE"
echo "JAR File: $JAR_FILE"
if [ -n "$JAR_MODIFIED" ]; then
    echo "JAR Modified: $JAR_MODIFIED"
fi
echo ""
echo "🔌 Connect debugger to: localhost:$DEBUG_PORT"
echo "   IntelliJ IDEA: Run → Attach to Process → localhost:$DEBUG_PORT"
echo "   VS Code: Add to launch.json: 'port': $DEBUG_PORT"
echo "   Command line: jdb -attach localhost:$DEBUG_PORT"
echo ""
echo "⏸️  Waiting for debugger connection..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run the validator with debug flags
# Aeron Cluster requires access to internal Java APIs for Agrona Unsafe access
java \
  --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED \
  -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:$DEBUG_PORT \
  -Dconsensus.enabled=true \
  -Dconsensus.mode=aeron \
  -Dconsensus.self.url="http://localhost:$HTTP_PORT" \
  -Dconsensus.peers="$PEERS" \
  -Daeron.cluster.nodeId=$NODE_ID \
  -Daeron.cluster.hostnames="localhost,localhost,localhost" \
  -Daeron.cluster.basePort=$CLUSTER_BASE_PORT \
  -Daeron.cluster.bootstrap=false \
  -Dwallet.keystore.path="$STORE_DIR/validator-keystore.properties" \
  -jar "$JAR_FILE" \
  --port $HTTP_PORT \
  --store "$STORE_DIR" \
  >> "$LOG_FILE" 2>&1

