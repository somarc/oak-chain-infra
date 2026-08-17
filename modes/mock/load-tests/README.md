# Load Test Scripts (Authoritative Suite)

Progressive load tests for validating Oak Chain performance and stability.

Prerequisites: Bash, curl, Python 3, OpenSSL, and `jq` when accepted-write capture is enabled.

## Ladder (Progressive Intensity)

| Script | Duration | Clients | Writes/Client | Binary Mix | Purpose |
|--------|----------|---------|---------------|------------|---------|
| `00-smoke-one-write.sh` | ~1 min | 1 | 1 | none | Sanity check (API + consensus path) |
| `01-light-5min.sh` | 5 min | 5 | 100–400 | 5% | Quick throughput check |
| `02-medium-15min.sh` | 15 min | 10 | 300–1200 | 10% | Sustained mixed load |
| `03-heavy-30min.sh` | 30 min | 15 | 500–5000 | 20% | Stress with mixed binary modes |
| `04-soak-2h.sh` | 2 hours | 20 | 1000–10000 | 15% | Long-running stability |
| `05-ultra-30min.sh` | 30 min | 30 | 2000–20000 | 40% | Single-node ultra stress |
| `06-ultra-ultra-multi-node.sh` | 30 min (default) | 36 (default) | 2000–20000 | 40% | Multi-node ingress fanout draft |
| `07-rejoin-drain-draft.sh` | 15 min (default) | via `06` | inherited | Follower kill/rejoin backlog drain draft |
| `08-proposal-persistence-sweep.sh` | 10 min/case (default) | 12 | 2000–6000 | 30% | Matrix sweep of persistence enabled + flush tuning |
| `10-e2e-write-delete-gc.sh` | depends on load profile | inherited | inherited | inherited | Fresh cluster -> load -> drain -> delete replay -> drain -> GC -> drain |
| `10-e2e-write-delete-gc-light.sh` | ~5–30 min | inherited (light profile default) | inherited | inherited | Lightweight e2e lifecycle sanity run with bounded deletes |
| `11-e2e-write-namespace-delete-gc.sh` | ~10–30 min | 1 (default) | 100 (default) | 5% | Fresh cluster -> write under one namespace -> single namespace delete proposal -> drain -> GC |
| `12-unreachable-pause-rejoin-draft.sh` | 15 min (default) | via `06` | inherited | inherited | Pause one follower process (SIGSTOP) during active load, then resume (SIGCONT) and evaluate catch-up |

Binary mix defaults:
- Validator-hosted binaries are the default effective path.
- Synthetic client-side `ipfsCid` traffic is disabled by default because the validator now requires known CID mappings for enterprise CID writes.
- Set `ALLOW_SYNTHETIC_IPFS_CIDS=true` only if you intentionally want the legacy synthetic-CID path (for example, to reproduce `unknown_ipfs_cid` rejections).

## How to Run

```bash
# Ensure validators are running
./local-dev.sh start validators --fresh

# Smoke test
./load-tests/00-smoke-one-write.sh

# Heavy test
./load-tests/03-heavy-30min.sh
```

## Config Knobs (Env Vars)

```bash
export VALIDATOR_URL=http://localhost:8090
export TEST_DURATION_SECONDS=1800
export NUM_CLIENTS=15
export MIN_WRITES_PER_CLIENT=500
export MAX_WRITES_PER_CLIENT=5000
export BINARY_PERCENT=20
export VALIDATOR_BINARY_PERCENT=30
export ALLOW_SYNTHETIC_IPFS_CIDS=false
export HTTP_CONNECT_TIMEOUT_SECONDS=3
export HTTP_REQUEST_TIMEOUT_SECONDS=30
export SLEEP_MIN_MS=25
export SLEEP_MAX_MS=200
export CAPTURE_WRITE_ACCEPTS=false
```

## Logs

Logs go to: `~/oak-chain/logs` by default. Override with `LOG_DIR`.

When `CAPTURE_WRITE_ACCEPTS=true`, accepted write responses are captured in:
- `~/oak-chain/logs/<test-name>-accepted-<timestamp>/client-<n>.ndjson`

## Monitoring

- `monitor-metrics.sh` — polls consensus/lag/pending and writes CSV log
- `monitor-validator-logs.sh` — tails validator logs with filtering and timestamps
- `queue-sampler.py` — samples mempool/queue stats from all validators into CSV
- `analyze-queue-samples.py` — computes ingest/verify/processed rates from sampler CSV
- `run-bottleneck-study.sh` — turnkey runner for all monitors with a fixed duration

## Benchmark Gate

Use the benchmark gate to answer: did we actually hit the target throughput, or only saturate on throttling/queueing?

```bash
# Default: heavy 30m profile, target 100k writes / 1800s
./load-tests/run-benchmark.sh

# Ultra profile with explicit target
./load-tests/run-benchmark.sh \
  --load-script ./load-tests/05-ultra-30min.sh \
  --target-writes 100000 \
  --target-duration 1800
```

What it does:
- Runs `leader-parity-preflight.py` before load and before scoring to ensure leader-sensitive counters are sampled from the active leader.
- Runs `queue-sampler.py` during the test.
- Runs your selected load script.
- Evaluates results via `benchmark-gate.py` using ADR-068 style gates.

Pass criteria:
- `throughput_target`: finalized throughput/volume meet target.
- `gap_control`: verified-finalized drift remains bounded.
- `queue_control`: pending/backpressure tail slope stays within bounds.
- `latency_control`: verifier queue wait remains under thresholds.
- `error_budget`: `429` rate stays within budget.
- `recovery_control`: pending tail is draining and end-of-window queue is bounded.

Tune thresholds without code changes:

```bash
export MAX_GAP_RATIO=0.30
export MAX_429_RATE=0.08
export MAX_VERIFIER_WAIT_AVG_MS=8000
./load-tests/run-benchmark.sh
```

Outputs:
- `~/oak-chain/logs/benchmark-run-*.log`
- `~/oak-chain/logs/benchmark-queue-*.csv`
- `~/oak-chain/logs/benchmark-report-*.json`
- `~/oak-chain/logs/benchmark-leader-parity-pre-*.env`
- `~/oak-chain/logs/benchmark-leader-parity-post-*.env`

Leader-parity controls:

```bash
# Force a specific scoring node (must be leader when checks run)
./load-tests/run-benchmark.sh --sample-node 8092

# Allow small temporary leader/sample counter mismatch (default 0)
./load-tests/run-benchmark.sh --max-counter-delta 5

# Disable parity checks (only for exploratory debugging)
./load-tests/run-benchmark.sh --skip-leader-parity
```

## Phase 3 Operations Gate (Concrete)

Use the execution checklist for go/no-go decisions after tuning changes:

- `./load-tests/PHASE-3-OPERATIONS-GATE.md`

## ADR-068 Checklist (Post-Run)

Use this to score existing artifacts (latest by default) and emit a pass/fail report:

```bash
./load-tests/adr068-checklist.sh
```

Strict mode fails if a gate metric is missing:

```bash
./load-tests/adr068-checklist.sh --strict-unknown
```

Leader parity is enforced by default (same source-of-truth guard as `run-benchmark.sh`):

```bash
# Score using validated leader-sensitive source node
./load-tests/adr068-checklist.sh --sample-node 8092

# Disable only for offline artifact triage
./load-tests/adr068-checklist.sh --skip-leader-parity
```

## Write Bounds Sweep

Use this to map write limits by stepping client counts and recording finalized throughput + drift + 429 pressure.

```bash
# Default sweep: clients 12,16,20,24,28,30; 10 min per step
./load-tests/map-write-bounds.sh

# Custom sweep
./load-tests/map-write-bounds.sh \
  --clients 10,14,18,22,26,30 \
  --duration 900 \
  --target-rps 55.5556
```

Outputs:
- `~/oak-chain/logs/write-bounds-summary-*.tsv`
- `~/oak-chain/logs/write-bounds-details-*.log`

## Multi-Node Ingress Draft

Draft `06-ultra-ultra-multi-node.sh` runs `run-load-test.sh` in parallel against all node ports.

```bash
./load-tests/06-ultra-ultra-multi-node.sh
```

Tunable env vars:

```bash
export NODES_CSV=8090,8092,8094
export NUM_CLIENTS_TOTAL=45
export TEST_DURATION_SECONDS=1800
./load-tests/06-ultra-ultra-multi-node.sh
```

## Rejoin Drain Draft

Draft `07-rejoin-drain-draft.sh` exercises follower crash/rejoin while load is active and captures queue trend CSV.

```bash
./load-tests/07-rejoin-drain-draft.sh
```

Tunable env vars:

```bash
export REJOIN_NODE_ID=2
export WARMUP_SECONDS=120
export DOWN_SECONDS=90
export TEST_DURATION_SECONDS=900
./load-tests/07-rejoin-drain-draft.sh
```

Note: by default this script disables the validator watchdog for controlled restart timing (`DISABLE_WATCHDOG=true`).

## Proposal Queue Persistence Toggle Notes

`queued-proposals.bin` durability is currently integral in the standard validator startup path.

- Persistence file location is `.../validator-<n>/proposal-queue/queued-proposals.bin`.
- Writes are atomic snapshot-replace via `.tmp` -> `.bin`.
- On restart, non-terminal proposals are restored into `unverifiedQueue`.

Current tuning knobs (already configurable):

- `oak.proposal.persistence.flush.ms` (default `250`)
- `oak.proposal.persistence.flush.batch` (default `100`)

Important:

- Use `OAK_PROPOSAL_PERSISTENCE_ENABLED=true|false` to toggle queue durability persistence.
- `OAK_PROPOSAL_PERSISTENCE_FLUSH_MS` and `OAK_PROPOSAL_PERSISTENCE_FLUSH_BATCH` tune flush cadence when persistence is enabled.
- Setting flush interval/batch to low values increases durability frequency but can increase IO overhead.

## Persistence Sweep Draft

Run matrix benchmarks over persistence mode + flush cadence:

```bash
./load-tests/08-proposal-persistence-sweep.sh
```

Default matrix:
- `p_on_default`: `enabled=true`, `flush.ms=250`, `flush.batch=100`
- `p_on_less_flush`: `enabled=true`, `flush.ms=1000`, `flush.batch=500`
- `p_on_more_flush`: `enabled=true`, `flush.ms=100`, `flush.batch=50`
- `p_off`: `enabled=false`

Outputs:
- `~/oak-chain/logs/persistence-sweep-summary-*.tsv`
- `~/oak-chain/logs/persistence-sweep-details-*.log`

## Live Evaluation Watcher

Use this during a running load test to classify real-time state and likely bottleneck.

```bash
./load-tests/watch-load-evaluation.sh
```

Outputs:
- console stream with state (`over_limit|near_limit|recovery|transitional`)
- likely bottleneck (`verifier|finalizer_or_sender|persistence|mixed_or_unknown`)
- CSV artifact: `~/oak-chain/logs/live-eval-*.csv`

## Delete Replay (Cleanup Draft)

Capture accepted writes during a load run, then replay delete proposals for those paths:

```bash
CAPTURE_WRITE_ACCEPTS=true ./load-tests/05-ultra-30min.sh
./load-tests/09-delete-replay.sh
```

Target a specific capture set:

```bash
./load-tests/09-delete-replay.sh \
  --input ~/oak-chain/logs/ultra-30min-accepted-20260208-120000 \
  --max-deletes 5000 \
  --sleep-ms 20
```

## End-to-End Lifecycle Run

Single command for: fresh cluster, load, validate drain, delete replay, validate drain, GC, validate drain.

```bash
./load-tests/10-e2e-write-delete-gc.sh
```

Lighter variant (recommended for quick validation):

```bash
./load-tests/10-e2e-write-delete-gc-light.sh
```

Light defaults:
- `LOAD_SCRIPT=./load-tests/01-light-5min.sh`
- `DELETE_MAX=500`
- `DELETE_SLEEP_MS=30`
- `WAIT_DRAIN_TIMEOUT_SECONDS=1800`
- `WAIT_DRAIN_POLL_SECONDS=5`
- `START_CLUSTER_ARGS=--fresh`

Useful overrides:

```bash
LOAD_SCRIPT=./load-tests/04-soak-2h.sh ./load-tests/10-e2e-write-delete-gc.sh
SKIP_CLUSTER_RESTART=true ./load-tests/10-e2e-write-delete-gc.sh
DELETE_MAX=10000 DELETE_SLEEP_MS=30 ./load-tests/10-e2e-write-delete-gc.sh
LOAD_SCRIPT=./load-tests/02-medium-15min.sh DELETE_MAX=2000 ./load-tests/10-e2e-write-delete-gc-light.sh
```

GC consensus/vote knobs:

```bash
# Auto-submit approval votes before execute (default true)
GC_AUTO_VOTE=true
# Validator IDs to cast votes as ("auto" discovers memberId list from /v1/aeron/cluster-state)
GC_VOTER_IDS=auto
# Approval wait tuning
GC_APPROVAL_TIMEOUT_SECONDS=300
GC_APPROVAL_POLL_SECONDS=5
```

## Namespace Delete E2E

Single-command lifecycle for large-tree delete behavior:
- write many nodes in one namespace (`client-1` by default)
- submit a single delete proposal for the parent namespace path
- validate drain, then run GC flow

```bash
./load-tests/11-e2e-write-namespace-delete-gc.sh
```

Useful overrides:

```bash
# Increase writes in the single namespace
MIN_WRITES_PER_CLIENT=500 MAX_WRITES_PER_CLIENT=500 LOAD_SCRIPT=./load-tests/11-namespace-delete-5min.sh \
  ./load-tests/11-e2e-write-namespace-delete-gc.sh

# Explicitly set namespace delete target path
NAMESPACE_DELETE_PATH=/oak-chain/74/2d/35/0x742d.../Client1/content \
  ./load-tests/11-e2e-write-namespace-delete-gc.sh

# Skip cluster restart if already running
SKIP_CLUSTER_RESTART=true ./load-tests/11-e2e-write-namespace-delete-gc.sh
```

## Legacy Scripts

Archived under `load-tests/archive/legacy-2026-02-03/`.
