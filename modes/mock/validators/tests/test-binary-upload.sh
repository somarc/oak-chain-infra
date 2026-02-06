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
source "$SCRIPT_DIR/config.sh"

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
BINARY_FILE="${1:-do-it-live.jpeg}"
TEST_WALLET="${TEST_WALLET:-0x03c6fced478cbbc9a4fab34ef9f40767739d1ff7}"
NODE_PATH="/oak-chain/content/demo/ipfs-test-$(date +%s)"

# Check if IPFS is running
check_ipfs() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🔍 Checking IPFS Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if ! command -v ipfs &> /dev/null; then
        echo -e "${RED}❌ IPFS not installed${NC}"
        echo -e "${YELLOW}   Install with: brew install ipfs${NC}"
        exit 1
    fi
    
    if ! curl -s http://127.0.0.1:5001/api/v0/version > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  IPFS daemon not running${NC}"
        echo -e "${YELLOW}   Starting IPFS daemon...${NC}"
        ipfs daemon > /dev/null 2>&1 &
        sleep 2
        echo -e "${GREEN}✅ IPFS daemon started${NC}"
    else
        echo -e "${GREEN}✅ IPFS daemon running${NC}"
    fi
    
    IPFS_VERSION=$(curl -s http://127.0.0.1:5001/api/v0/version | jq -r '.Version' 2>/dev/null || echo "unknown")
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
    
    # Check if IPFS BlobStore is enabled
    DASHBOARD=$(curl -s "$VALIDATOR_URL/")
    if echo "$DASHBOARD" | grep -q "IPFS BlobStore"; then
        echo -e "${GREEN}✅ IPFS BlobStore enabled${NC}"
    else
        echo -e "${YELLOW}⚠️  IPFS BlobStore may not be enabled${NC}"
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
    
    TX_HASH="0x$(openssl rand -hex 32)"
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
        -d "signature=0xmocksig" \
        -d "paymentTier=standard")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
        echo -e "${GREEN}✅ Proposal submitted (HTTP $HTTP_CODE)${NC}"
        echo -e "${CYAN}   TX Hash: $TX_HASH${NC}"
        echo -e "${CYAN}   Wallet: $TEST_WALLET${NC}"
        echo -e "${CYAN}   Binary: $(basename "$BINARY_FILE") (${FILE_SIZE_KB} KB)${NC}"
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
    
    echo -e "${YELLOW}   STANDARD tier: ~12.8 minutes (2-epoch finality)${NC}"
    echo -e "${YELLOW}   Waiting 30 seconds for write to complete...${NC}"
    
    for i in {30..1}; do
        echo -ne "${CYAN}   ⏱️  $i seconds remaining...\r${NC}"
        sleep 1
    done
    echo -e "\n${GREEN}✅ Wait complete${NC}"
}

# Check if node exists in Oak
check_oak_node() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🌳 Checking Oak Node${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    NODE_RESPONSE=$(curl -s "$VALIDATOR_URL/api/explore-node?path=$NODE_PATH")
    
    if echo "$NODE_RESPONSE" | grep -q "jcr:data"; then
        echo -e "${GREEN}✅ Node exists in Oak${NC}"
        echo -e "${CYAN}   Path: $NODE_PATH${NC}"
        
        # Try to extract CID if present
        CID=$(echo "$NODE_RESPONSE" | jq -r '.properties."jcr:data" // .["jcr:data"] // empty' 2>/dev/null | grep -o "Qm[a-zA-Z0-9]*" | head -1)
        if [ ! -z "$CID" ]; then
            echo -e "${GREEN}✅ Found CID in jcr:data${NC}"
            echo -e "${CYAN}   CID: $CID${NC}"
        else
            echo -e "${YELLOW}   ⚠️  CID not found in response (may be inline)${NC}"
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
    
    # Check if our expected CID is pinned
    if [ ! -z "$EXPECTED_CID" ]; then
        if echo "$PINS" | grep -q "$EXPECTED_CID"; then
            echo -e "${GREEN}✅ Expected CID is pinned: $EXPECTED_CID${NC}"
        else
            echo -e "${YELLOW}⚠️  Expected CID not found in pins${NC}"
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
    echo -e "${CYAN}   Oak Node Path: $NODE_PATH${NC}"
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

