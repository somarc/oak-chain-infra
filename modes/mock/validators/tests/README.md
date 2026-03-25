# Validator Tests (Mock Mode)

Focused validation scripts for local validator clusters, organized by test
intent instead of historical file drift.

Old top-level commands are preserved as wrappers for compatibility, but new
work should prefer the categorized paths below.

## Layout

- `lib/`
  - Shared cluster helpers used by the focused stability tests.
- `smoke/`
  - Cheap control-plane and schema sanity checks.
- `routing/`
  - Sharding ownership, redirect, and cross-cluster visibility proofs.
- `stability/`
  - Isolated Aeron recovery probes for failover, catch-up, and quorum loss.
- `surfaces/`
  - End-to-end proposal mutation coverage.
- `integration/`
  - Cross-system integrations such as binary/IPFS persistence.
- `manual/`
  - Broad endpoint enumeration and ad hoc diagnostics.

## Recommended Gates

- `surfaces/proposal-surfaces-3x2.sh`
  - Primary mock-mode acceptance gate.
  - Proves 3x2 bring-up, routing, writes, deletes, wallet namespace delete,
    failover, catch-up, quorum loss, and post-stability revalidation.
- `integration/test-binary-upload.sh`
  - Primary binary/IPFS integration gate.
  - Proves binary proposal acceptance, Oak node materialization, IPFS CID
    persistence, pinning, and byte-for-byte retrieval.
- `smoke/validator-api-smoke.sh`
  - Cheap control-plane baseline for health, consensus, Aeron, and queue
    endpoints across nodes.

## Extended Or Targeted Checks

- `routing/sharding-3x2-smoke.sh`
  - Fast two-cluster sharding and redirect proof.
- `routing/sharding-3x3-smoke.sh`
  - Three-cluster authoritative routing proof.
- `stability/aeron-warm-failover-smoke.sh`
  - Repeated failover loop for confidence in recovery over multiple cycles.
- `stability/*.sh`
  - Focused isolation tests when a specific stability behavior regresses.
- `manual/oak_api_smoke.sh`
  - Endpoint enumerator for manual inspection; not a formal gate.

## Prerequisites

- Validator cluster running, or a suite that can start one.
- `curl` and `python3` installed.
- `jq` recommended.
- Local IPFS available when running binary/IPFS or proposal suites.

## Usage

```bash
# Cheap control-plane baseline
./smoke/validator-api-smoke.sh

# Fast routing proof
./routing/sharding-3x2-smoke.sh

# Primary proposal-surface acceptance gate
bash ./surfaces/proposal-surfaces-3x2.sh

# Binary/IPFS integration proof
./integration/test-binary-upload.sh

# Backward-compatible wrapper entrypoints still work
./validator-api-smoke.sh
bash ./proposal-surfaces-3x2.sh
./test-binary-upload.sh
```
