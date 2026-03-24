# IPFS CID Architecture & Implementation

## Current State: CID Missing from UI

**Observation**: Binary content shows `jcr:data` but no visible `ipfsCid` property.

**Root Cause**: Mock mode uses **MemoryBlobStore** which doesn't integrate with IPFS.

---

## Architecture Overview (ADR 015-016)

### The Two-Tier Binary Storage Model

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Oak Segments (Structured Content)                      │
│  - Content tree, properties, metadata                           │
│  - Small data inline in segments                                │
│  - References to external blobs via blob IDs                    │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼ (reference)
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: Binary DataStore (Large Binaries)                      │
│  - IPFS for content-addressed storage                           │
│  - Blob ID = IPFS CID (content identifier)                      │
│  - P2P replication via IPFS network                             │
└─────────────────────────────────────────────────────────────────┘
```

### Author-Owned IPFS Model (ADR 016)

**Key Principle**: Sling authors upload to **their own IPFS nodes**, validators store **CID only**.

```
┌──────────────┐           ┌──────────────┐           ┌──────────────┐
│ Sling Author │           │  Validator   │           │ IPFS Network │
└──────┬───────┘           └──────┬───────┘           └──────┬───────┘
       │                          │                          │
       │ 1. Upload binary         │                          │
       ├─────────────────────────>│                          │
       │    to own IPFS           │                          │
       │                          │                          │
       │<─────────────────────────┤                          │
       │ 2. Get CID (Qm...)       │                          │
       │                          │                          │
       │ 3. POST /v1/propose-write│                          │
       │    (binaryData + ipfsCid)│                          │
       ├─────────────────────────>│                          │
       │                          │                          │
       │                          │ 4. Store both:           │
       │                          │    - Oak blob ID         │
       │                          │    - IPFS CID            │
       │                          │                          │
       │                          │ 5. Verify CID exists     │
       │                          ├─────────────────────────>│
       │                          │    (optional check)      │
       │                          │                          │
```

---

## Where CID Should Be Stored

### Code Location

`WriteApplicationService.java:335-348`:

```java
// Handle IPFS CID
if (ipfsCid != null && !ipfsCid.isEmpty()) {
    contentNode.setProperty("ipfsCid", ipfsCid);
    contentNode.setProperty("ipfsGateway", "https://ipfs.io/ipfs/" + ipfsCid);
    log.info("✅ Binary stored with client-provided IPFS CID...");
} else {
    // Try to derive CID from validator's IPFSDataStore (legacy path)
    String derivedCid = tryDeriveCidFromBlobStore(blobId);
    if (derivedCid != null) {
        contentNode.setProperty("ipfsCid", derivedCid);
        contentNode.setProperty("ipfsGateway", "https://ipfs.io/ipfs/" + derivedCid);
        log.info("✅ Binary stored with validator-derived IPFS CID (legacy)...");
    } else {
        log.info("✅ Binary stored (no IPFS CID - client should provide)...");
    }
}
```

### Expected Properties

When CID is stored correctly:

```json
{
  "jcr:data": "ed06f9cb8fe87801...#22216",
  "jcr:blobId": "ed06f9cb8fe87801...#22216",
  "jcr:mimeType": "image/jpeg",
  "ipfsCid": "QmXYZ123...",
  "ipfsGateway": "https://ipfs.io/ipfs/QmXYZ123..."
}
```

---

## Why CID Is Missing: Mock Mode Analysis

### Current Setup (Mock Mode)

```java
// GlobalStoreServer.java - Mock mode configuration
BlobStore blobStore = new MemoryBlobStore();
```

**MemoryBlobStore characteristics:**
- ✅ Stores blobs in memory (fast for testing)
- ✅ Returns SHA-256 hex blob IDs
- ❌ **No IPFS integration**
- ❌ **No CID generation**
- ❌ `tryDeriveCidFromBlobStore()` returns `null`

### Flow in Mock Mode

```
Test script → base64 binary → POST /v1/propose-write
                                       ↓
                              MemoryBlobStore.writeBlob()
                                       ↓
                              Returns: ed06f9cb...#22216
                                       ↓
                         contentNode.setProperty("jcr:blobId", blobId)
                         tryDeriveCidFromBlobStore(blobId) → null
                                       ↓
                         No ipfsCid property set ❌
```

---

## Solution Paths

### Option 1: Enable IPFSDataStore (Production-like)

**When to use**: Testing full IPFS integration, preparing for production.

**Steps**:

1. **Install IPFS** (kubo):
   ```bash
   brew install kubo  # macOS; the CLI binary remains `ipfs`
   # OR
   # Download the current release for your OS/arch from:
   # https://github.com/ipfs/kubo/releases
   curl -LO https://dist.ipfs.tech/kubo/<version>/kubo_<version>_darwin-arm64.tar.gz
   tar xvf kubo_<version>_darwin-arm64.tar.gz
   cd kubo
   sudo ./install.sh
   ```

2. **Initialize IPFS**:
   ```bash
   ipfs init
   ipfs daemon &  # Start in background
   ```

3. **Configure Validator** (`GlobalStoreServer.java`):
   ```java
   // Replace MemoryBlobStore with IPFSDataStore
   if ("ipfs".equals(System.getProperty("blobstore.type", "memory"))) {
       String ipfsApiUrl = System.getProperty("ipfs.api.url", "http://127.0.0.1:5001");
       blobStore = new org.apache.jackrabbit.oak.blob.cloud.ipfs.IPFSDataStore(ipfsApiUrl);
       log.info("✅ IPFSDataStore initialized: {}", ipfsApiUrl);
   } else {
       blobStore = new MemoryBlobStore();
       log.info("✅ MemoryBlobStore initialized (mock mode)");
   }
   ```

4. **Start validator** with IPFS:
   ```bash
   java -Dblobstore.type=ipfs \
        -Dipfs.api.url=http://127.0.0.1:5001 \
        -jar oak-segment-consensus.jar --port 8090 ...
   ```

5. **Verify**:
   ```bash
   # Check IPFS is running
   ipfs id
   
   # Upload test
   ipfs add /path/to/image.jpg
   # Returns: QmXYZ...
   
   # Retrieve
   ipfs cat QmXYZ...
   ```

### Option 2: Client-Side IPFS Upload (ADR 016 - Recommended)

**When to use**: Production deployment, author-owned binaries.

**Flow**:

```bash
# 1. Author uploads to their IPFS node
IPFS_CID=$(ipfs add -Q /path/to/binary.jpg)

# 2. Author sends CID + binary to validator
curl -X POST "http://localhost:8090/v1/propose-write" \
  -d "walletAddress=0x742d..." \
  -d "binaryData=$(base64 < /path/to/binary.jpg)" \
  -d "ipfsCid=${IPFS_CID}" \
  -d "mimeType=image/jpeg" \
  ...
```

**Validator stores**:
- `jcr:blobId`: Internal Oak blob ID (may still use MemoryBlobStore)
- `ipfsCid`: Client-provided CID
- `ipfsGateway`: Public gateway URL

**Why this works**:
- ✅ Works even with MemoryBlobStore
- ✅ Author controls binary availability (via their IPFS node)
- ✅ Validators don't need to run IPFS
- ✅ Binaries available via public IPFS gateways

### Option 3: Hybrid (Current + Fix Test Script)

**Quick fix for testing**:

Modify test script to send mock CID:

```bash
# In write-binary-delete-gc-test.sh
if [ "$include_binary" = true ]; then
    # Generate mock IPFS CID (CIDv1 format)
    MOCK_CID="bafybeig$(openssl rand -hex 16)"
    
    response=$(curl -X POST "${VALIDATOR_URL}/v1/propose-write" \
        -d "binaryData=${binary_base64}" \
        -d "ipfsCid=${MOCK_CID}" \  # ← Add this
        -d "mimeType=${binary_mime}" \
        ...)
fi
```

**Result**: CID appears in properties even with MemoryBlobStore.

---

## Verification & Testing

### Check Current BlobStore Type

```bash
# Check validator startup logs
grep -i "blobstore.*initialized" ~/oak-chain/logs/validator-0.log

# Expected outputs:
# MemoryBlobStore: "MemoryBlobStore initialized (mock mode)"
# IPFSDataStore:   "IPFSDataStore initialized: http://127.0.0.1:5001"
```

### Check for CID Properties

```bash
# Via API
curl -s "http://localhost:8090/api/explore-node?path=/oak-chain/.../content-1" | jq '.properties | {ipfsCid, ipfsGateway, "jcr:blobId"}'

# Expected with CID:
# {
#   "ipfsCid": "QmXYZ...",
#   "ipfsGateway": "https://ipfs.io/ipfs/QmXYZ...",
#   "jcr:blobId": "ed06f9cb...#22216"
# }
```

### Test IPFS Retrieval

If CID is present:

```bash
# Via IPFS CLI
ipfs cat QmXYZ...

# Via public gateway
curl https://ipfs.io/ipfs/QmXYZ...

# Via Cloudflare gateway (faster)
curl https://cloudflare-ipfs.com/ipfs/QmXYZ...
```

---

## Production Deployment Checklist

### For Validators

- [ ] Run IPFS daemon (`ipfs daemon`)
- [ ] Configure IPFSDataStore in validator
- [ ] Set `blobstore.type=ipfs`
- [ ] Set `ipfs.api.url=http://127.0.0.1:5001`
- [ ] Monitor IPFS storage growth
- [ ] Configure IPFS garbage collection policy

### For Sling Authors

- [ ] Run own IPFS node
- [ ] Upload binaries to own IPFS first
- [ ] Send CID + binaryData to validators
- [ ] Ensure IPFS node stays online (for initial seeding)
- [ ] Monitor IPFS pinning (keep important content)

### For Test Scripts

- [ ] Upload to IPFS first (get CID)
- [ ] Send CID along with binary data
- [ ] Verify CID in response
- [ ] Test binary retrieval via IPFS gateway

---

## Economics & GC Implications

### Why CID Matters for GC (ADR 017)

When content is deleted:

1. **Oak segments** marked for GC (tracked in GC debt)
2. **IPFS binaries** can be unpinned:
   ```bash
   ipfs pin rm QmXYZ...
   ```
3. **IPFS GC** reclaims space:
   ```bash
   ipfs repo gc
   ```

### Cost Model

```
Delete cost = Oak segment GC cost + IPFS storage cost

Oak GC:     $0.10 per MB (validator overhead)
IPFS unpin: Free (just metadata)
IPFS GC:    Automatic (when unpinned)
```

**CID enables**:
- Validators verify binary exists before accepting delete
- Validators unpin from IPFS after delete confirmed
- IPFS network GC reclaims space automatically

---

## Recommended Next Steps

### Short-term (Current Test)

1. ✅ **Accept current state** - MemoryBlobStore works for functional testing
2. ⚠️ **Note limitation** - No IPFS CIDs in mock mode (expected)
3. ℹ️ **Document** - CID will appear when IPFSDataStore enabled

### Medium-term (Enhanced Testing)

1. **Install IPFS locally**
2. **Enable IPFSDataStore** in mock mode
3. **Update test script** to send CIDs
4. **Verify** full IPFS integration

### Long-term (Production)

1. **Kubernetes IPFS** - Deploy IPFS cluster
2. **Sling IPFS client** - Upload from Sling authors
3. **CID verification** - Validators check CID availability
4. **IPFS monitoring** - Track storage growth, replication

---

## Summary

| Aspect | Current (Mock) | With IPFSDataStore | With Client Upload (ADR 016) |
|--------|---------------|-------------------|------------------------------|
| BlobStore | MemoryBlobStore | IPFSDataStore | Any (even Memory) |
| CID in properties | ❌ No | ✅ Yes (auto) | ✅ Yes (explicit) |
| Binary availability | Memory only | IPFS + Memory | IPFS (author's node) |
| Validator IPFS | Not needed | Required | Optional |
| Production ready | No | Partial | ✅ Yes |

**Recommendation**: Implement **Client Upload (ADR 016)** for production. This is the most scalable and aligns with author-owned binary model.

---

## References

- **ADR 015**: IPFS DataStore for binaries
- **ADR 016**: Author-owned IPFS (validators store CIDs only)
- **ADR 017**: DataStore GC tokenomics
- **ADR 019**: Direct Binary Access
- **ADR 020**: Lazy upload on confirmation

**See**: `OAK/jackrabbit-oak/oak-segment-consensus/IPFS-DATASTORE.md`
