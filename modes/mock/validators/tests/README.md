# Validator Tests (Mock Mode)

Focused validation scripts for local validator clusters, organized by test
intent instead of historical file drift.

Old top-level commands are preserved as wrappers for compatibility, but new
work should prefer the categorized paths below.

The normative design and evidence requirements for new consensus validation
work are in [CONSENSUS-TEST-CHARTER.md](CONSENSUS-TEST-CHARTER.md). Existing
scripts are not formal gates unless they satisfy that charter's assertion and
evidence contract.

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
- `monitoring/`
  - Periodic staircase watcher and failure-investigation capture.

## Transactions And Wallets

Every write and delete these tests send is valid under the runtime's contract
(`../../TRANSACTION-CONTRACT.md`), built by the shared builder `oak-chain tx`
through `../../lib/oak-tx.sh`: signed by `walletAddress` over exactly the
message (or `contentPath` for deletes), `ethereumTxHash = proposalId` (mock
settlement), no `paymentTier`. Wallets must be test keys we hold
(`../../lib/test-wallets.tsv`). A wallet address passed in env (for example
`WALLET_A=0x1100…0`) selects the held test key with the same first byte, so it
still routes to the same shard; roles therefore use distinct first bytes.

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
- `monitoring/mock-scale-staircase-monitor.sh`
  - Watches a live staircase run log, emits progress snapshots, and captures
    an investigation bundle when the run stalls or fails.

## Extended Or Targeted Checks

- `routing/sharding-3x2-smoke.sh`
  - Fast two-cluster sharding and redirect proof.
- `routing/sharding-3x3-smoke.sh`
  - Three-cluster authoritative routing proof.
- What both routing smokes assert, through `lib/_sharding_health_lib.sh`
  (JSON checks in `lib/sharding_health.py`):
  - on every member of every cluster, not just validator-0: `sharding.enabled`,
    `localPrefixes`, `remoteMountCount` (a config echo, kept as sanity) and
    `authoritativeStoreSeparated`;
  - `sharding.configDigest` is identical across the members of each cluster; a
    divergent member is named by port;
  - before any routing or visibility assertion, every member reports
    `remoteEndpointsAvailable == remoteEndpointCount` within `READ_TIMEOUT_SECONDS`;
    otherwise the smoke fails with each unavailable mount's endpoint, circuit and
    `lastError`;
  - write messages carry a per-run nonce (`SMOKE_RUN_NONCE`, default
    timestamp-pid-random), so a rerun on a reused runtime root cannot pass on
    content an earlier run left behind.
  - They require a runtime whose `/health` reports per-mount health
    (`configDigest`, `remoteEndpointCount`, `remoteEndpointsAvailable`,
    `remoteMounts`); against an older runtime they fail fast, naming
    `oak-segment-consensus` `fix/cluster-of-clusters-phase0`.
- `surfaces/proposal-surfaces-3x2.sh` runs the same mount gate before every
  "absent on all ports" check: a member whose remote mount is down answers 404
  for remote paths, so absence would otherwise pass vacuously.
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
- Local IPFS available when running binary/IPFS or proposal suites. Its gateway
  belongs on `127.0.0.1:5080`, off every validator port; an older `~/.ipfs`
  keeps `8099` until reconfigured (`../TROUBLESHOOTING.md`, IPFS gateway on a
  validator port).

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

Run the staircase monitor in a second terminal:

```bash
cd /Users/mhess/aem/aem-code/OAK
bash oak-chain-infra/modes/mock/validators/tests/mock-scale-staircase-monitor.sh \
  --run-log /tmp/oak-mock-scale-staircase-overnight.log \
  --artifact-root /tmp/oak-mock-scale-staircase-artifacts
```

Monitor defaults:

- run log: `/tmp/oak-mock-scale-staircase-overnight.log`
- artifact root: `/tmp/oak-mock-scale-staircase-artifacts`
- poll interval: `30s`
- monitor timeout: `0s` (disabled)
- stall threshold: `900s`
- terminal-state confirmation: `3` retries with `5s` sleeps

If the monitor declares a stall or failure, it writes an investigation bundle
under:

- `/tmp/oak-mock-scale-staircase-artifacts/monitoring/mock-scale-staircase-investigation-<timestamp>/`

If you customize topology config packs, keep Aeron base-port blocks disjoint
across clusters. A 5-node cluster started at `9000` consumes `9000-9405`, so
the next cluster must not reuse `9400`.

To add a hard monitor timeout, pass `--timeout-seconds <n>` or set
`MONITOR_TIMEOUT_SECONDS=<n>`. A value of `0` keeps the monitor open-ended.

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

## Latest Validated Result

As of `2026-03-26`, the mock staircase lane is green across staged reruns with
local IPFS.

Validated phases:

- `phase-01-single-cluster-3`: pass
- `phase-02-single-cluster-5`: pass
- `phase-03-dual-5x3`: pass
- `phase-04-triple-5x3x3`: pass
- `phase-05-soak`: pass across `12` cycles on the full `5+3+3` fabric

Latest terminal success:

```text
[2026-03-26 09:53:10] SUCCESS mock-scale-staircase completed
[2026-03-26 09:53:10] Artifacts written to /tmp/oak-mock-scale-staircase-artifacts
```

Interpretation:

- This is a correctness-and-recovery proof, not a load or throughput result.
- The full acceptance picture was established through staged reruns while
  runtime and harness defects were being corrected.
- The latest fully successful run covered the final `5+3+3` fabric phase plus
  the bounded soak lane; earlier phases had already passed in prior reruns.

Artifacts:

- `mock-scale-staircase.sh` defaults to `/tmp/oak-mock-scale-staircase-artifacts`
- `proposal-surfaces-single-cluster.sh` defaults to `/tmp/oak-proposal-surfaces-single-cluster-artifacts`
- `proposal-surfaces-3x2.sh` defaults to `/tmp/oak-proposal-surfaces-3x2-artifacts`
- `mock-scale-staircase-monitor.sh` defaults to `/tmp/oak-mock-scale-staircase-artifacts/monitoring/mock-scale-staircase-investigation-<timestamp>`
