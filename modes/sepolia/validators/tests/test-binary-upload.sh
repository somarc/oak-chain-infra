#!/bin/bash
# Test IPFS Binary Upload - Do It Live! 🎉
# 
# Purpose: Test IPFS DataStore by uploading a binary (image) via standard paid proposal
# Features:
# - Uploads binary file (do-it-live.jpeg)
# - Verifies IPFS CID storage
# - Checks binary retrieval
# - Validates IPFS pinning

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    # Optional local overrides for validator URL, wallets, and fixture paths.
    source "$SCRIPT_DIR/config.sh"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
VALIDATOR_URL="${VALIDATOR_URL:-http://localhost:8090}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DEFAULT_BINARY_FILE="${REPO_ROOT}/fixtures/binaries/do-it-live.jpeg"
BINARY_FILE="${1:-$DEFAULT_BINARY_FILE}"
TEST_WALLET="${TEST_WALLET:-0x03c6fced478cbbc9a4fab34ef9f40767739d1ff7}"
WRITE_WAIT_SECONDS="${WRITE_WAIT_SECONDS:-90}"
OPERATION_ID=""
STORAGE_PATH=""

# Check if IPFS is running
check_ipfs() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🔍 Checking IPFS Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if ! command -v ipfs &> /dev/null; then
        echo -e "${RED}❌ IPFS not installed${NC}"
        echo -e "${YELLOW}   Install with: brew install kubo${NC}"
        exit 1
    fi
    
    if ! curl -s -X POST http://127.0.0.1:5001/api/v0/version > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  IPFS daemon not running${NC}"
        echo -e "${YELLOW}   Starting IPFS daemon...${NC}"
        ipfs daemon > /dev/null 2>&1 &
        sleep 2
        echo -e "${GREEN}✅ IPFS daemon started${NC}"
    else
        echo -e "${GREEN}✅ IPFS daemon running${NC}"
    fi
    
    IPFS_VERSION=$(curl -s -X POST http://127.0.0.1:5001/api/v0/version | jq -r '.Version' 2>/dev/null || echo "unknown")
    echo -e "${CYAN}   Version: ${IPFS_VERSION}${NC}"
}

# Check validator status
check_validator() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🏛️  Checking Validator Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if ! curl -s -f "$VALIDATOR_URL/health" > /dev/null 2>&1; then
        echo -e "${RED}❌ Validator not responding at $VALIDATOR_URL${NC}"
        echo -e "${YELLOW}   Start with: ./local-dev.sh start validators${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Validator online${NC}"
    
    HEALTH_JSON=$(curl -s "$VALIDATOR_URL/health")
    BLOBSTORE_ACTIVE=$(echo "$HEALTH_JSON" | jq -r '.blobStoreActive // false' 2>/dev/null || echo "false")
    BLOBSTORE_TYPE=$(echo "$HEALTH_JSON" | jq -r '.blobStoreType // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$BLOBSTORE_ACTIVE" = "true" ]; then
        echo -e "${GREEN}✅ BlobStore active (${BLOBSTORE_TYPE})${NC}"
    else
        echo -e "${YELLOW}⚠️  BlobStore not reported active${NC}"
        echo -e "${YELLOW}   Set: export BLOBSTORE_TYPE=ipfs${NC}"
    fi
}

# Check binary file
check_binary() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📦 Checking Binary File${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [ ! -f "$BINARY_FILE" ]; then
        echo -e "${RED}❌ Binary file not found: $BINARY_FILE${NC}"
        echo -e "${YELLOW}   Usage: $0 <path-to-binary-file>${NC}"
        exit 1
    fi
    
    FILE_SIZE=$(stat -f%z "$BINARY_FILE" 2>/dev/null || stat -c%s "$BINARY_FILE" 2>/dev/null)
    FILE_SIZE_KB=$((FILE_SIZE / 1024))
    FILE_TYPE=$(file -b --mime-type "$BINARY_FILE")
    
    echo -e "${GREEN}✅ Binary file found${NC}"
    echo -e "${CYAN}   Path: $BINARY_FILE${NC}"
    echo -e "${CYAN}   Size: ${FILE_SIZE_KB} KB${NC}"
    echo -e "${CYAN}   Type: $FILE_TYPE${NC}"
    
    if [ $FILE_SIZE -lt 16384 ]; then
        echo -e "${YELLOW}   ⚠️  Warning: File < 16KB (will be stored inline in segments, not IPFS)${NC}"
    else
        echo -e "${GREEN}   ✓ File ≥ 16KB (will be stored in IPFS)${NC}"
    fi
}

# Upload binary to IPFS (for comparison)
upload_to_ipfs() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📤 Pre-Upload to IPFS (for CID comparison)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "${YELLOW}   Uploading to IPFS...${NC}"
    IPFS_RESPONSE=$(ipfs add --quiet "$BINARY_FILE")
    EXPECTED_CID=$(echo "$IPFS_RESPONSE" | awk '{print $1}')
    
    echo -e "${GREEN}✅ Uploaded to IPFS${NC}"
    echo -e "${CYAN}   Expected CID: $EXPECTED_CID${NC}"
    
    # Unpin it (we want validator to pin it, not us)
    ipfs pin rm "$EXPECTED_CID" > /dev/null 2>&1 || true
}

# Convert binary to base64 for JSON
binary_to_base64() {
    base64 < "$BINARY_FILE"
}

# Create write proposal with binary
submit_proposal() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}✍️  Submitting Write Proposal with Binary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "${YELLOW}   Encoding binary to base64...${NC}"
    BINARY_BASE64=$(binary_to_base64)
    
    echo -e "${YELLOW}   Creating proposal...${NC}"
    
    TX_HASH="0x$(openssl rand -hex 32 2>/dev/null || date +%s%N)"
    SIGNATURE="0x$(openssl rand -hex 65 2>/dev/null || printf '%0130d' 0)"
    MIME_TYPE=$(file -b --mime-type "$BINARY_FILE")
    
    echo -e "${YELLOW}   Submitting to validator (form-encoded)...${NC}"
    
    # Use form-encoded data (matching 30min-economics-test.sh pattern)
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$VALIDATOR_URL/v1/propose-write" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "walletAddress=$TEST_WALLET" \
        -d "ethereumTxHash=$TX_HASH" \
        -d "contentType=file" \
        -d "message=[IPFS TEST] Binary upload: $(basename "$BINARY_FILE") ($MIME_TYPE)" \
        -d "binaryData=$BINARY_BASE64" \
        -d "mimeType=$MIME_TYPE" \
        -d "signature=$SIGNATURE" \
        -d "paymentTier=standard")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
        OPERATION_ID=$(echo "$RESPONSE_BODY" | jq -r '.operationId // .proposalId // empty' 2>/dev/null || true)
        STORAGE_PATH=$(echo "$RESPONSE_BODY" | jq -r '.storagePath // empty' 2>/dev/null || true)
        echo -e "${GREEN}✅ Proposal submitted (HTTP $HTTP_CODE)${NC}"
        echo -e "${CYAN}   TX Hash: $TX_HASH${NC}"
        echo -e "${CYAN}   Wallet: $TEST_WALLET${NC}"
        echo -e "${CYAN}   Binary: $(basename "$BINARY_FILE") (${FILE_SIZE_KB} KB)${NC}"
        if [ -n "$OPERATION_ID" ]; then
            echo -e "${CYAN}   Operation ID: $OPERATION_ID${NC}"
        fi
        if [ -n "$STORAGE_PATH" ]; then
            echo -e "${CYAN}   Storage Path: $STORAGE_PATH${NC}"
        fi
        if [ ! -z "$RESPONSE_BODY" ]; then
            echo -e "${CYAN}   Response: $RESPONSE_BODY${NC}"
        fi
    else
        echo -e "${RED}❌ Proposal failed (HTTP $HTTP_CODE)${NC}"
        echo -e "${RED}   Response: $RESPONSE_BODY${NC}"
        exit 1
    fi
}

# Wait for write to be processed
wait_for_write() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}⏳ Waiting for Write to be Processed${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [ -z "$OPERATION_ID" ]; then
        echo -e "${RED}❌ Missing operationId in proposal response${NC}"
        exit 1
    fi

    echo -e "${YELLOW}   Polling operation status for up to ${WRITE_WAIT_SECONDS} seconds...${NC}"

    local remaining=$WRITE_WAIT_SECONDS
    while [ "$remaining" -gt 0 ]; do
        OPERATION_RESPONSE=$(curl -s "$VALIDATOR_URL/v1/ops/operations/$OPERATION_ID")
        OPERATION_STATE=$(echo "$OPERATION_RESPONSE" | jq -r '.state // empty' 2>/dev/null || true)
        SOURCE_STATE=$(echo "$OPERATION_RESPONSE" | jq -r '.sourceState // "unknown"' 2>/dev/null || echo "unknown")
        DURABILITY_STATE=$(echo "$OPERATION_RESPONSE" | jq -r '.durabilityState // "unknown"' 2>/dev/null || echo "unknown")

        if [ "$OPERATION_STATE" = "COMMITTED" ]; then
            echo -e "${GREEN}✅ Operation committed${NC}"
            echo -e "${CYAN}   Source State: $SOURCE_STATE${NC}"
            echo -e "${CYAN}   Durability State: $DURABILITY_STATE${NC}"
            return
        fi

        if [ "$OPERATION_STATE" = "FAILED" ] || [ "$OPERATION_STATE" = "REJECTED" ] || [ "$OPERATION_STATE" = "TIMED_OUT" ]; then
            echo -e "${RED}❌ Operation ended in state: $OPERATION_STATE${NC}"
            echo -e "${YELLOW}   Response: $OPERATION_RESPONSE${NC}"
            exit 1
        fi

        echo -ne "${CYAN}   ⏱️  ${remaining}s remaining | state=${OPERATION_STATE:-unknown} source=${SOURCE_STATE} durability=${DURABILITY_STATE}\r${NC}"
        sleep 2
        remaining=$((remaining - 2))
    done

    echo ""
    echo -e "${RED}❌ Timed out waiting for operation to commit${NC}"
    echo -e "${YELLOW}   Last response: $OPERATION_RESPONSE${NC}"
    exit 1
}

# Check if node exists in Oak
check_oak_node() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🌳 Checking Oak Node${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [ -z "$STORAGE_PATH" ]; then
        echo -e "${RED}❌ Missing storagePath in proposal response${NC}"
        exit 1
    fi

    ENCODED_PATH=$(printf '%s' "$STORAGE_PATH" | jq -sRr @uri)
    NODE_RESPONSE=$(curl -s "$VALIDATOR_URL/api/explore?path=$ENCODED_PATH")

    if echo "$NODE_RESPONSE" | jq -e '.properties."jcr:data"' > /dev/null 2>&1; then
        BINARY_DESCRIPTOR=$(echo "$NODE_RESPONSE" | jq -r '.properties."jcr:data" // empty')
        STORED_CID=$(echo "$NODE_RESPONSE" | jq -r '.properties."ipfsCid" // empty')
        STORED_BLOB_ID=$(echo "$NODE_RESPONSE" | jq -r '.properties."jcr:blobId" // empty')
        STORAGE_MODE=$(echo "$NODE_RESPONSE" | jq -r '.properties."oak:binaryStorageMode" // empty')

        echo -e "${GREEN}✅ Node exists in Oak${NC}"
        echo -e "${CYAN}   Path: $STORAGE_PATH${NC}"

        if [[ "$BINARY_DESCRIPTOR" == \[Binary:* ]]; then
            echo -e "${GREEN}✅ jcr:data stored as Oak binary${NC}"
            echo -e "${CYAN}   $BINARY_DESCRIPTOR${NC}"
        else
            echo -e "${RED}❌ jcr:data is not stored as a binary${NC}"
            echo -e "${YELLOW}   Value: $BINARY_DESCRIPTOR${NC}"
            exit 1
        fi

        if [ -n "$STORED_BLOB_ID" ]; then
            echo -e "${GREEN}✅ Found jcr:blobId${NC}"
            echo -e "${CYAN}   Blob ID: $STORED_BLOB_ID${NC}"
        else
            echo -e "${RED}❌ Missing jcr:blobId${NC}"
            exit 1
        fi

        if [ -n "$STORED_CID" ]; then
            echo -e "${GREEN}✅ Found ipfsCid${NC}"
            echo -e "${CYAN}   CID: $STORED_CID${NC}"
            if [ -n "$EXPECTED_CID" ] && [ "$STORED_CID" != "$EXPECTED_CID" ]; then
                echo -e "${YELLOW}⚠️  Stored CID differs from pre-upload CID${NC}"
                echo -e "${YELLOW}   Expected: $EXPECTED_CID${NC}"
            fi
        else
            echo -e "${RED}❌ Missing ipfsCid${NC}"
            exit 1
        fi

        if [ -n "$STORAGE_MODE" ]; then
            echo -e "${GREEN}✅ Storage mode recorded${NC}"
            echo -e "${CYAN}   oak:binaryStorageMode: $STORAGE_MODE${NC}"
        fi
    else
        echo -e "${RED}❌ Node not found in Oak${NC}"
        echo -e "${YELLOW}   Response: $NODE_RESPONSE${NC}"
        exit 1
    fi
}

# Check IPFS pinned CIDs
check_ipfs_pins() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📌 Checking IPFS Pins${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "${YELLOW}   Querying IPFS pins...${NC}"
    PINS=$(ipfs pin ls --type=recursive 2>/dev/null || echo "")
    
    if [ -z "$PINS" ]; then
        echo -e "${YELLOW}⚠️  No pins found${NC}"
        return
    fi
    
    echo -e "${GREEN}✅ Pinned CIDs:${NC}"
    echo "$PINS" | while read -r line; do
        CID=$(echo "$line" | awk '{print $1}')
        echo -e "${CYAN}   • $CID${NC}"
    done
    
    if [ ! -z "$EXPECTED_CID" ]; then
        PIN_STATUS=$(ipfs pin ls --type=all "$EXPECTED_CID" 2>/dev/null || true)
        if [ -n "$PIN_STATUS" ]; then
            PIN_TYPE=$(echo "$PIN_STATUS" | awk '{print $2}' | head -n1)
            echo -e "${GREEN}✅ Expected CID pin state: ${PIN_TYPE:-unknown} (${EXPECTED_CID})${NC}"
        else
            echo -e "${RED}❌ Expected CID is not pinned: $EXPECTED_CID${NC}"
            exit 1
        fi
    fi
}

# Retrieve binary from IPFS
retrieve_from_ipfs() {
    if [ -z "$EXPECTED_CID" ]; then
        echo -e "${YELLOW}⚠️  No CID to retrieve${NC}"
        return
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📥 Retrieving Binary from IPFS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    RETRIEVED_FILE="/tmp/retrieved-$(basename "$BINARY_FILE")"
    
    echo -e "${YELLOW}   Fetching CID: $EXPECTED_CID${NC}"
    if ipfs cat "$EXPECTED_CID" > "$RETRIEVED_FILE" 2>/dev/null; then
        echo -e "${GREEN}✅ Binary retrieved from IPFS${NC}"
        echo -e "${CYAN}   Saved to: $RETRIEVED_FILE${NC}"
        
        # Compare checksums
        ORIGINAL_MD5=$(md5 -q "$BINARY_FILE" 2>/dev/null || md5sum "$BINARY_FILE" | awk '{print $1}')
        RETRIEVED_MD5=$(md5 -q "$RETRIEVED_FILE" 2>/dev/null || md5sum "$RETRIEVED_FILE" | awk '{print $1}')
        
        if [ "$ORIGINAL_MD5" == "$RETRIEVED_MD5" ]; then
            echo -e "${GREEN}✅ Checksums match!${NC}"
            echo -e "${CYAN}   MD5: $ORIGINAL_MD5${NC}"
        else
            echo -e "${RED}❌ Checksums don't match!${NC}"
            echo -e "${CYAN}   Original:  $ORIGINAL_MD5${NC}"
            echo -e "${CYAN}   Retrieved: $RETRIEVED_MD5${NC}"
        fi
    else
        echo -e "${RED}❌ Failed to retrieve from IPFS${NC}"
    fi
}

# Show IPFS stats
show_ipfs_stats() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📊 IPFS Repository Stats${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    REPO_STATS=$(ipfs repo stat 2>/dev/null || echo "{}")
    REPO_SIZE=$(echo "$REPO_STATS" | grep "RepoSize" | awk '{print $2}')
    NUM_OBJECTS=$(echo "$REPO_STATS" | grep "NumObjects" | awk '{print $2}')
    
    if [ ! -z "$REPO_SIZE" ]; then
        echo -e "${CYAN}   Repository Size: $REPO_SIZE bytes${NC}"
        echo -e "${CYAN}   Number of Objects: $NUM_OBJECTS${NC}"
    else
        echo -e "${YELLOW}   Stats not available${NC}"
    fi
}

# Main execution
main() {
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}🚀 IPFS Binary Upload Test - DO IT LIVE! 🎉${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    check_ipfs
    check_validator
    check_binary
    upload_to_ipfs
    submit_proposal
    wait_for_write
    check_oak_node
    check_ipfs_pins
    retrieve_from_ipfs
    show_ipfs_stats
    
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ IPFS Binary Upload Test Complete!${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}📝 Summary:${NC}"
    echo -e "${CYAN}   Binary File: $BINARY_FILE${NC}"
    echo -e "${CYAN}   Operation ID: $OPERATION_ID${NC}"
    echo -e "${CYAN}   Oak Node Path: $STORAGE_PATH${NC}"
    echo -e "${CYAN}   Expected CID: $EXPECTED_CID${NC}"
    echo -e "${CYAN}   Test Wallet: $TEST_WALLET${NC}"
    echo ""
    echo -e "${YELLOW}💡 Next Steps:${NC}"
    echo -e "${YELLOW}   1. Check validator dashboard: $VALIDATOR_URL${NC}"
    echo -e "${YELLOW}   2. View IPFS repo: ipfs repo stat${NC}"
    echo -e "${YELLOW}   3. List all pins: ipfs pin ls${NC}"
    echo -e "${YELLOW}   4. Retrieve binary: ipfs cat $EXPECTED_CID${NC}"
    echo ""
}

# Run main
main
