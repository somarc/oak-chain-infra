# Load Test Issues & Fixes

## Issue 1: macOS `head -n -1` Incompatibility ✅ FIXED

**Problem**: Script used `head -n -1` to strip HTTP status code from curl output.

```bash
# Linux (works)
response=$(curl -s -w "\n%{http_code}" ...)
body=$(echo "$response" | head -n -1)  # Works on Linux

# macOS (fails)
head: illegal line count -- -1
```

**Fix**: Use `sed '$d'` instead (works on both macOS and Linux)

```bash
body=$(echo "$response" | sed '$d')  # Remove last line - macOS compatible
```

**Status**: ✅ Fixed in `write-binary-delete-gc-test.sh`

---

## Issue 2: Path Sharding Violation ✅ FIXED

**Problem**: Script wrote to `/oak-chain/test-gc-20260116-220406/content-1` (flat path).

**Error**:
```
HTTP 403: Path ownership violation
Only content under /oak-chain/74/2d/35/0x742d35cc6634c0532925a3b844bc9e7595f0beb0/ can be deleted
```

**Root Cause**: Oak-Chain uses **wallet-based path sharding** (ADR 046).

**Correct Path Structure**:
```
/oak-chain/{shard-prefix}/{wallet-lowercase}/content/...

Example:
Wallet: 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0
Shard:  74/2d/35 (first 3 bytes of wallet, hex-encoded)
Path:   /oak-chain/74/2d/35/0x742d35cc6634c0532925a3b844bc9e7595f0beb0/content-1
```

**Why This Matters**:
- **Ownership verification**: Only the wallet owner can write/delete content under their shard
- **Deterministic sharding**: `hash(wallet) → shard → validator assignment`
- **Cross-cluster reads**: Composite mounts work because of predictable paths
- **Layer 1 architecture**: Wallet address IS the namespace

**Fix Applied**:
```bash
# Calculate wallet-sharded path
WALLET_LOWER=$(echo "$TEST_WALLET" | tr '[:upper:]' '[:lower:]')
SHARD_PREFIX="${WALLET_LOWER:2:2}/${WALLET_LOWER:4:2}/${WALLET_LOWER:6:2}"
WALLET_ROOT="/oak-chain/${SHARD_PREFIX}/${WALLET_LOWER}"

# Use wallet-sharded path
content_path="${WALLET_ROOT}/test-gc-${TIMESTAMP}/content-${i}"
```

**Status**: ✅ Fixed in `write-binary-delete-gc-test.sh`

---

## Issue 3: Missing IPFS CID in UI 🔬 INVESTIGATION

**Observation**: UI shows `jcr:data` property with Oak blob ID, but no visible `ipfsCid` property.

**Expected Properties**:
```javascript
{
  "jcr:data": "ed06f9cb8fe87801...#22216",      // Oak blob ID
  "jcr:blobId": "ed06f9cb8fe87801...#22216",   // Raw blob ID  
  "ipfsCid": "QmXYZ...",                         // IPFS CID
  "ipfsGateway": "https://ipfs.io/ipfs/QmXYZ...", // Gateway URL
  "jcr:mimeType": "image/jpeg"
}
```

**Where CID is Set** (from `WriteApplicationService.java:336`):
```java
if (ipfsCid != null && !ipfsCid.isEmpty()) {
    contentNode.setProperty("ipfsCid", ipfsCid);
    contentNode.setProperty("ipfsGateway", "https://ipfs.io/ipfs/" + ipfsCid);
    log.info("✅ Binary stored with client-provided IPFS CID...");
}
```

**Root Cause Analysis**:

The test script sends `binaryData` (base64) directly, but **does NOT upload to IPFS first**.

**Current Flow** (incomplete):
```
Client → base64 encode → POST to validator
                              ↓
                        writeBlob()
                              ↓
                        Store blob ID only
                        (no IPFS CID)
```

**Correct Flow** (ADR 016 - Author-Owned IPFS):
```
Client → Upload to IPFS → Get CID → POST (binaryData + ipfsCid) → Validator
                                                                        ↓
                                                                   Store both:
                                                                   - blob ID (Oak)
                                                                   - CID (IPFS reference)
```

**Why This Matters** (ADR 016):
- **Author-owned IPFS**: Sling authors upload to their own IPFS nodes
- **Validators store CID only**: Not responsible for hosting binaries
- **Binary availability**: IPFS P2P network handles replication
- **DataStore GC**: Validators can verify CID exists before GC cleanup

**Test Script Issue**:

The script encodes binary and sends to validator, but validator's BlobStore might be:
1. **MemoryBlobStore** (mock mode) - No IPFS, just stores blob ID
2. **IPFSDataStore** - Would upload to IPFS and return CID as blob ID

**Check Current BlobStore Type**:
```bash
grep "BlobStore.*initialized" ~/oak-chain/logs/validator-0.log
```

Expected output:
```
# Mock mode (MemoryBlobStore)
BlobStore: MemoryBlobStore initialized

# Production (IPFSDataStore)  
IPFSDataStore: Connected to IPFS at /ip4/127.0.0.1/tcp/5001
IPFSDataStore: CID mapping service initialized
```

**Two-Part Fix Needed**:

### Part 1: Validator-Side (Check BlobStore)

If using IPFSDataStore, the CID *should* be automatically extracted from blob ID:

```java
// From WriteApplicationService.java:340-348
String derivedCid = tryDeriveCidFromBlobStore(blobId);
if (derivedCid != null) {
    contentNode.setProperty("ipfsCid", derivedCid);
    contentNode.setProperty("ipfsGateway", "https://ipfs.io/ipfs/" + derivedCid);
}
```

**Check**: Is `tryDeriveCidFromBlobStore()` working?

### Part 2: Test Script (Send CID Explicitly)

For complete testing, script should:
1. Upload to IPFS first (get CID)
2. Send CID + binaryData to validator
3. Validator stores both

**Enhanced Test Flow**:
```bash
# 1. Upload to IPFS (requires ipfs CLI or kubo API)
IPFS_CID=$(ipfs add -Q "$BINARY_FILE")

# 2. Send with CID
curl -X POST "${VALIDATOR_URL}/v1/propose-write" \
  -d "binaryData=${binary_base64}" \
  -d "ipfsCid=${IPFS_CID}" \
  -d "mimeType=${binary_mime}" \
  ...
```

**Status**: 🔬 Needs investigation

**Next Steps**:
1. Check validator logs for BlobStore type
2. Check if `ipfsCid` property exists but UI not showing it
3. If using MemoryBlobStore (mock), CID won't exist (expected)
4. If using IPFSDataStore, check `tryDeriveCidFromBlobStore()` implementation

---

## Issue 4: EDS (port 3000) Not Working 🔍 SEPARATE

**Observation**: Frontend at http://localhost:3000 not working.

**Previous Fix**: Killed stale process on port 3000.

**Current Status**: Unknown - needs separate investigation.

**Check**:
```bash
# Is EDS running?
lsof -ti :3000

# Check EDS logs
tail -f ~/oak-chain/logs/eds.log
```

**Likely Causes**:
1. Process killed, not restarted
2. EDS build issues (`npm install` needed)
3. Config pointing to wrong validator URL

**Fix** (if needed):
```bash
cd OAK/blockchain-aem-eds
npm install
npx serve -p 3000
```

---

## Summary

| Issue | Status | Severity | Fix |
|-------|--------|----------|-----|
| macOS `head -n -1` | ✅ Fixed | High | Use `sed '$d'` |
| Path sharding | ✅ Fixed | Critical | Use wallet-sharded paths |
| IPFS CID missing | 🔬 Investigating | Medium | Check BlobStore type |
| EDS not working | 🔍 Separate | Low | Restart EDS server |

---

## Run Fixed Test

```bash
cd /Users/mhess/aem/aem-code/OAK/blockchain-aem-infra/scripts/local-development/load-tests
./write-binary-delete-gc-test.sh
```

**Expected Result**:
- ✅ 50 writes (20 with binaries)
- ✅ 10 deletes (20% ratio)
- ✅ No `head: illegal line count` errors
- ✅ No 403 path ownership errors

**IPFS CID Investigation** (post-test):
```bash
# Check if CID property exists
curl -s "http://localhost:8090/api/explore-node?path=/oak-chain/74/2d/35/0x742d35cc6634c0532925a3b844bc9e7595f0beb0/test-gc-*/content-1" | jq '.properties'
```

Look for `ipfsCid` property in output.
