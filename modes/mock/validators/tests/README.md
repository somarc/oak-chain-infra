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
- `routing/federation-3x2-smoke.sh`
  - Enterprise-federation proof on the `fed-3x2` topology (two clusters, one
    enterprise each, a static-file directory instead of `oak.sharding.*`
    routes). Needs a jar from `jackrabbit-oak` `feature/enterprise-federation`.
  - Assumes both clusters run (`../lifecycle/start-fed-3x2.sh`); never starts,
    stops or signals anything. It writes the shared directory file itself.
  - Phases: P0 preflight (members up, pids, one jar sha256, launch flags),
    P1 charter (one charterDigest and clusterId per cluster,
    `charterMatchesConfig`, different clusterIds; `400
    namespace_requires_federation` before any directory), P2 directory epoch
    E1 (all six members converge on one digest; content, prevDigest,
    `federated`, `localNamespaces`), P3 writes and deletes (own-namespace 202
    committed on every member, `307 wrong_cluster` with the owner's first
    endpoint, listed writer into another namespace 202 with the wallet node's
    `wallet` = the namespace, `403 writer_not_authorized`, `403
    namespace_unclaimed`), P4 cross-cluster reads through verified directory
    mounts, P5 directory epoch E2 (writer removed: prevDigest chains, the
    writer gets 403), P6 end state (health, pids unchanged, no unexpected
    5xx, no ERROR-level federation lines appended to any validator log).
  - E1 is one above the committed (or file) epoch, so a rerun on kept roots
    continues at E1+2; the unfederated 400 probe then becomes a diagnostic
    UNKNOWN (start with `--fresh` to cover it).
  - Bounded: under 30 write/delete requests, a deadline on every wait
    (`FED_SMOKE_DEADLINE_SECONDS`, default 60; `FED_SMOKE_POLL_MS`, default
    2000); aborts on the first unexpected 5xx or a member that stops answering
    and leaves everything running. Tolerated: `no_quorum` retries and `503`
    from a mount that is still unavailable, both recorded.
  - Evidence: one sealed (read-only) directory per run,
    `$FED_3X2_ROOT/evidence/<UTC timestamp>/` with `manifest.json`,
    `requests.ndjson`, `snapshots/<phase>/`, `directory-epoch-N.json`,
    `log-scan.json`, `assertions.tsv` (PASS / FAIL / UNKNOWN), `summary.json`
    and `report.md`. Logic and fixture tests: `src/federation-smoke.mjs`,
    `test/federation-smoke.test.mjs`. Exit 0 PASS, 1 FAIL, 2 refused.
  - `status.localNamespaces` is the count of namespaces the local enterprise
    owns; which ones is asserted on the committed directory.
- `routing/federation-3x2-failover.sh`
  - ONE bounded fault on the running `fed-3x2` topology, after the smoke
    (directory committed, A owns nsA1). Logic: `src/federation-failover.mjs`
    on the shared evidence session `src/federation-session.mjs`; fake-federation
    tests: `test/federation-failover.test.mjs` (`fixtures/fake-federation.mjs`).
  - F0 picks the victim: the cluster-A endpoint most B members' directory
    mounts read from (`activeEndpoint`; ties to the lowest member), records
    whether it leads A and its pid. F1 commits a baseline nsA1 write, read by
    every B member. F2 stops exactly the victim with
    `lifecycle/member.sh stop N` under `config/fed-3x2-cluster-a.env` (graceful;
    member.sh escalates after `STOP_WAIT_SECONDS`), sampling B reads meanwhile.
    F3, within `FED_FAILOVER_SECONDS` (90) of the stop: a leader among the
    survivors commits a second write on both; every B mount for A is verified
    and available on another endpoint; until then each B read of the baseline
    is the content or a 503, never missing (outcomes counted); then both writes
    read on every B member. F4 restarts the victim with `member.sh start N`
    (the launch record's jar): UP within `FED_RECOVERY_SECONDS` (120) with its
    peers' charterDigest, clusterId and directory digest, serving both writes.
    F5: six members up, no other pid changed, no 5xx but the fault-window
    mount 503s; the log scan is reported (diagnostic: the outage may log).
  - On any other surprise it aborts and leaves everything as it is; a victim
    left stopped is named with its restart command in `report.md`. Evidence:
    `$FED_3X2_ROOT/evidence/failover-<UTC>/` (smoke format plus
    `failover.json`, `member-stop.log`, `member-start.log`).
- `routing/federation-3x2-gc.sh`
  - Member-local segment GC and binary GC on federation cluster B, observed
    through cluster A's directory mount. Needs a jar from `jackrabbit-oak`
    `feature/consensus-gc-safety` (it serves `GET /v1/gc/status`). Logic:
    `src/federation-gc.mjs` on `src/federation-session.mjs`; tests:
    `test/federation-gc.test.mjs` (pure judgements plus end-to-end runs
    against `fixtures/fake-gc-federation.mjs`).
  - Launch: cluster B with the GC test profile, cluster A on the defaults,
    then the smoke (it commits the directory in which B owns nsB1):
    `FED_3X2_B_GC_JAVA_OPTS=test OAK_CONSENSUS_JAR=… ../lifecycle/start-fed-3x2.sh --fresh`.
    The profile (`FED_3X2_GC_TEST_JAVA_OPTS`, `lifecycle/lib/fed-3x2.sh`):
    `oak.gc.tail.interval.ms=60000`, `oak.gc.full.interval.ms=120000`,
    `oak.gc.backoff=0`, `oak.gc.estimation.size.delta.bytes=0`,
    `oak.gc.binary.interval.ms=60000`, `oak.gc.binary.grace.ms=60000`,
    `oak.gc.binary.delete.delay.ms=30000`. It is in B's launch record; a
    `member.sh` restart of a B member under `config/fed-3x2-cluster-b.env`
    needs the same `FED_3X2_B_GC_JAVA_OPTS` (the environment's
    `EXTRA_JAVA_OPTS` wins over the record's). The scenario itself never
    starts, stops or signals anything.
  - G0 preflight: six members up, one jar; B's launch record carries the
    profile and A's no `-Doak.gc.*`; `/v1/gc/status` on all six (B reports the
    profile, A the defaults); B owns nsB1; every A mount of B verified and
    available; B's binary delete counters as the baseline. G1: 2 control
    messages, 16 bulk messages of 180000 characters (~2.9 MB) and 4
    validator-hosted binaries of 20 KiB (multipart upload) into nsB1, all
    committed and present on every B member, the binaries in the replicated
    index (`/:oak-chain-binaries/aa/bb/<sha-256>`) on every B member, all read
    on A through the mount. G2: a continuous reader starts on A (control
    items, two bulk items, the deleted binaries and the nsB1 listing, every
    `FED_GC_READER_MS`); every bulk message and 3 of the 4 binaries are
    deleted (absent on every B member and through every A mount). G3, within
    `FED_GC_SECONDS` (600) of the last delete: each B member reports two
    completed full runs started after the deletes, with reclaimed bytes and a
    smaller store (latest `sizeAfter` < first `sizeBefore`); binary GC
    released the deleted binaries on every B member (`lastRelease`, index
    entries 404, `deletes.ok + absent` grown by 3 with nothing pending). G4:
    the reader is judged and both clusters checked for logical convergence.
  - Required assertions: `members-up`, `same-jar`,
    `b-launched-with-gc-profile`, `a-launched-with-gc-defaults`,
    `gc-status-present`, `b-gc-settings-applied`, `a-gc-settings-default`,
    `directory-uniform`, `nsB1-owned-by-B`, `a-mounts-b-ready`,
    `writes-accepted`, `writes-committed`, `writes-on-every-b-member`,
    `binaries-stored`, `binaries-indexed`, `a-reads-before-delete`,
    `deletes-accepted`, `deletes-committed`, `deletes-absent-on-b`,
    `deletes-absent-through-a`, `segment-gc-b0..b2`, `binary-gc-released`,
    `binary-index-entries-released`, `binary-records-deleted`,
    `a-control-never-missing` (every A read of control content is the content
    or a `503 mount_stale`/`mount_unavailable`: never missing, never a 500),
    `a-mount-503-bounded` (at most `FED_GC_MAX_503_FRACTION` 0.1 of control
    reads, no 503 streak over `FED_GC_MAX_503_STREAK_SECONDS` 30 per A
    member), `a-doomed-present-until-deleted`, `b-converged-control`,
    `b-converged-deleted`, `b-listing-converged`, `a-converged-control`,
    `a-converged-deleted`, `a-listing-converged`, `a-own-content-converged`,
    `control-binary-kept` (index entry and bytes on every B member),
    `members-up-end`, `no-restarts`, `no-unexpected-5xx`. Diagnostics: GC
    run timings and sizes per member, stagger (lag behind each member's slot,
    overlapping runs), failed/cancelled runs, release counts, delete
    failures, deleted bytes still served, A's GC idle, the log scan.
  - Duration: about 8 to 10 minutes (G0-G2 about 2, G3 typically 4 to 7, at
    most `FED_GC_SECONDS`); 41 operations (charter budget 50).
  - Proves: on B, Oak's own tail/full GC runs per member on the configured
    slots, reclaims the space of deleted content and shrinks the store;
    binary GC releases only unreferenced binaries through a replicated
    release and every member's local delete covers them; through all of it a
    remote reader on A never sees control content vanish or a 500, only
    bounded `503 mount_*`; both clusters stay logically converged. Does not
    prove: GC at production intervals or under write load (charter 4.1: no
    GC concurrent with write pressure), cluster A's GC, GC across a member
    restart or leader change, Kubo block reclamation (Kubo's own GC), or
    behaviour with separate IPFS nodes per member (all local clusters share
    one Kubo, so a member that did not delete a record counts it `absent`).
  - Evidence: `$FED_3X2_ROOT/evidence/gc-<UTC>/` in the smoke's format plus
    `gc.json` (items with paths, blob ids, CIDs and sha256s; the timeline;
    every reader read; every GC run seen per member; binary GC state). Bulk
    payloads are recorded as length + sha256. Exit 0 PASS, 1 FAIL, 2 refused.
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

# Enterprise federation proof (clusters from ../lifecycle/start-fed-3x2.sh)
OAK_CONSENSUS_JAR=/abs/path/oak-segment-consensus.jar ./routing/federation-3x2-smoke.sh
# One bounded fault on the same clusters, after the smoke
OAK_CONSENSUS_JAR=/abs/path/oak-segment-consensus.jar ./routing/federation-3x2-failover.sh
# GC on cluster B (launched with FED_3X2_B_GC_JAVA_OPTS=test), after the smoke
OAK_CONSENSUS_JAR=/abs/path/oak-segment-consensus.jar ./routing/federation-3x2-gc.sh

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
