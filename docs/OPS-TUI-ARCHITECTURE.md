# Oak Chain Operator TUI Architecture

## Decision

Evolve the existing operator CLI into a read-only-first cluster operations board. Do not move lifecycle, telemetry authority, or log storage into the terminal renderer.

Ownership remains explicit:

- `jackrabbit-oak` owns validator runtime facts and governed telemetry contracts.
- `oak-chain-edge-worker` owns browser/operator-safe `/ops/v1/*` aggregation.
- `oak-chain-infra` owns lifecycle adapters, operator profiles, and the TUI.
- The TUI is a replaceable view over those contracts, not a second control plane.

## First Slice

`oak-chain ops board` polls these governed OPS surfaces:

- `/ops/v1/overview`
- `/ops/v1/health`
- `/ops/v1/cluster`
- `/ops/v1/queue`
- `/ops/v1/signals`
- `/ops/v1/events/recent`

For mock-local operation only, it also tails bounded portions of active logs under `$CLUSTER_RUNTIME_ROOT/logs`. Remote profiles should pass `--no-local-logs`; production log aggregation belongs behind an authenticated, redacted query adapter.

The first slice is intentionally read-only. Start/stop remains explicit through `oak-chain mock up|down|status`, which continues to delegate to the proven shell scripts.

## Production Boundary

The production board should consume a stable `ops.board.v1` snapshot assembled from independently versioned sources. A snapshot should include:

- cluster identity, environment, topology, quorum, leader, term, and freshness
- per-validator health, role, reachability, build/release identity, and clock skew
- queue depth, admission rate, finalization rate, backpressure, and oldest-item age
- replication position/lag with a declared measurement timestamp
- Aeron error, timeout, retransmit, and backpressure counters
- storage, IPFS/blob-store, disk, memory, CPU, file-descriptor, and GC posture
- recent governed domain events
- active alerts and telemetry-source failures
- links/correlation IDs into centralized logs and traces

Missing or stale telemetry must render as `unknown`, never as healthy zeroes.

## Lifecycle Event Contract

The shell scripts should next gain an optional JSON Lines event sink while retaining human-readable output:

```json
{"version":"lifecycle.event.v1","time":"...","clusterId":"single-cluster","operationId":"...","phase":"validator.start","target":"validator-0","status":"started","pid":7843}
```

Required fields are `version`, `time`, `clusterId`, `operationId`, `phase`, `target`, and `status`. Optional fields may include `durationMs`, `pid`, `endpoint`, `errorCode`, and a redacted `message`. This lets the TUI show startup progress without scraping terminal prose.

## Staged Evolution

1. **Read-only local board (current):** governed telemetry, recent events, bounded local error view, explicit freshness and source failures.
2. **Structured lifecycle events:** JSONL output from start/stop/status scripts; TUI progress pane and operation history.
3. **Safe actions:** authenticated start/stop/restart/drain workflows with confirmation, precondition checks, operation IDs, and audit records. Never bind production mutations directly to a single keypress.
4. **Central observability:** OpenTelemetry metrics/traces/log correlation; durable log backend; alert acknowledgement and runbook links.
5. **Fleet mode:** multiple clusters and environments, RBAC, read-only default profiles, release/config drift, SLOs, and incident timelines.

## Safety Invariants

- One seed/OPS URL is enough to discover the cluster; node lists are not hardcoded in the TUI.
- Read-only and mutating credentials are distinct.
- Every mutation is authenticated, confirmed, idempotent where possible, and auditable.
- The board displays observation time and source failure separately from cluster failure.
- Local logs are a development adapter, not the production logging design.
- Shell lifecycle scripts remain directly usable for recovery when the TUI is unavailable.
