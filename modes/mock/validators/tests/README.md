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
- `suites/`
  - Top-level orchestrators that combine multiple focused tests into a larger acceptance run.
- `integration/`
  - Cross-system integrations such as binary/IPFS persistence.
- `manual/`
  - Broad endpoint enumeration and ad hoc diagnostics.

## Recommended Gates

- `surfaces/proposal-surfaces-3x2.sh`
  - Primary mock-mode acceptance gate.
  - Proves 3x2 bring-up, routing, writes, deletes, wallet namespace delete,
    failover, catch-up, quorum loss, and post-stability revalidation.
- `surfaces/proposal-surfaces-single-cluster.sh`
  - Primary single-cluster mutation and stability gate.
  - Proves writes, deletes, wallet namespace delete, graceful restart, hard
    crash, follower catch-up, and size-aware quorum envelope in one cluster.
- `integration/test-binary-upload.sh`
  - Primary binary/IPFS integration gate.
  - Proves binary proposal acceptance, Oak node materialization, IPFS CID
    persistence, pinning, and byte-for-byte retrieval.
- `suites/mock-scale-staircase.sh`
  - Full staircase acceptance run.
  - Walks through single-cluster 3-node, single-cluster 5-node, dual-cluster
    5+3, triple-cluster 5+3+3, and optional soak cycles.
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
- `stability/aeron-quorum-envelope-smoke.sh`
  - Size-aware quorum threshold proof.
  - Verifies tolerated failures still allow commits and the next loss produces
    `no_quorum`.
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

# Single-cluster acceptance gate
bash ./surfaces/proposal-surfaces-single-cluster.sh

# Primary proposal-surface acceptance gate
bash ./surfaces/proposal-surfaces-3x2.sh

# Binary/IPFS integration proof
./integration/test-binary-upload.sh

# Full staircase run
bash ./suites/mock-scale-staircase.sh

# Backward-compatible wrapper entrypoints still work
./validator-api-smoke.sh
bash ./proposal-surfaces-single-cluster.sh
bash ./proposal-surfaces-3x2.sh
bash ./mock-scale-staircase.sh
./test-binary-upload.sh
```

## Exact Run Commands

Run all commands from the repo root:

```bash
cd /Users/mhess/aem/aem-code/OAK
```

Start local IPFS in one terminal:

```bash
cd /Users/mhess/aem/aem-code/OAK
ipfs daemon
```

Run the full staircase acceptance suite in another terminal:

```bash
cd /Users/mhess/aem/aem-code/OAK
AUTO_START_IPFS=false \
bash oak-chain-infra/modes/mock/validators/tests/suites/mock-scale-staircase.sh
```

If you customize topology config packs, keep Aeron base-port blocks disjoint
across clusters. A 5-node cluster started at `9000` consumes `9000-9405`, so
the next cluster must not reuse `9400`.

Run the longer staircase plus soak variant:

```bash
cd /Users/mhess/aem/aem-code/OAK
AUTO_START_IPFS=false \
RUN_WARM_FAILOVER=true \
WARM_FAILOVER_CYCLES=3 \
SOAK_CYCLES=8 \
SOAK_WRITE_COUNT_PER_ORG=8 \
SOAK_BINARY_INTERVAL=2 \
bash oak-chain-infra/modes/mock/validators/tests/suites/mock-scale-staircase.sh
```

Run the focused single-cluster 3-node acceptance gate:

```bash
cd /Users/mhess/aem/aem-code/OAK
AUTO_START_IPFS=false \
CLUSTER_CONFIG=/Users/mhess/aem/aem-code/OAK/oak-chain-infra/modes/mock/validators/config/single-cluster-3.env \
bash oak-chain-infra/modes/mock/validators/tests/surfaces/proposal-surfaces-single-cluster.sh
```

Run the focused single-cluster 5-node acceptance gate:

```bash
cd /Users/mhess/aem/aem-code/OAK
AUTO_START_IPFS=false \
CLUSTER_CONFIG=/Users/mhess/aem/aem-code/OAK/oak-chain-infra/modes/mock/validators/config/single-cluster-5.env \
bash oak-chain-infra/modes/mock/validators/tests/surfaces/proposal-surfaces-single-cluster.sh
```

Run the primary 3x2 proposal-surface acceptance gate:

```bash
cd /Users/mhess/aem/aem-code/OAK
AUTO_START_IPFS=false \
bash oak-chain-infra/modes/mock/validators/tests/surfaces/proposal-surfaces-3x2.sh
```

Artifacts:

- `mock-scale-staircase.sh` defaults to `/tmp/oak-mock-scale-staircase-artifacts`
- `proposal-surfaces-single-cluster.sh` defaults to `/tmp/oak-proposal-surfaces-single-cluster-artifacts`
- `proposal-surfaces-3x2.sh` defaults to `/tmp/oak-proposal-surfaces-3x2-artifacts`
