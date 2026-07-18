# Oak Segment Consensus Test Charter

**Status:** Draft v0.1 for review
**Scope:** Three-member Aeron Cluster / Raft-style Oak Segment Consensus in local mock mode
**Primary owner:** `oak-chain-infra/modes/mock/validators/tests/`
**Runtime implementation:** `jackrabbit-oak/oak-segment-consensus`
**Canonical orientation:** FluffyJaws artifact `a_7614f54cfa96c4d75af2`

## 1. Purpose

This charter defines the evidence required to make credible claims about a three-validator Oak Segment Consensus cluster. It is intentionally stricter than the existing smoke, surface, staircase, and load scripts: a script exit code or HTTP 202 is not sufficient proof of consensus correctness.

The suite must answer five distinct questions:

1. Did Aeron commit one ordered command history under quorum?
2. Did every validator apply the committed commands to the same **logical Oak state**?
3. Did every accepted proposal reach one explainable terminal outcome?
4. Did acknowledged committed effects survive the tested crash/restart boundary?
5. Did the cluster remain within a bounded resource and operational envelope on one Mac?

It must not confuse these questions with physical Segment/TAR identity. Independent stores may produce different RecordIds, journal tips, TAR layouts, and byte representations while holding equivalent logical content.

## 2. Non-negotiable correctness model

### 2.1 Oracle hierarchy

The suite uses this order of authority:

1. **Recorded operation history** — invocation, acceptance, state transitions, terminal outcome, and response times.
2. **Recursive strict logical-state digest** — all nodes, sorted children, sorted properties, types, and exact values.
3. **Expected-state model** — ordered writes/deletes applied by an offline checker.
4. **Aeron native evidence** — role, member ID, quorum, log position, election timeline, and snapshot events.
5. **Durability evidence** — operation durability state, flush acknowledgements, restart survival, and store reopen.
6. **Physical storage diagnostics** — RecordId, journal, TAR inventory, sparse/logical size, allocated size, and hashes.

Health endpoints, dashboards, Prometheus counters, and script success messages are observations to cross-check, not standalone correctness oracles.

### 2.2 Logical versus physical equality

A consensus pass requires exact recursive logical equality unless a scenario explicitly tests an expected transient state. It does **not** require:

- equal Segment RecordIds;
- byte-identical TAR files;
- identical journal lines;
- equal compaction layout;
- equal sparse-file allocation.

Physical evidence is retained to diagnose divergence and recovery, not used as the primary convergence assertion.

### 2.3 Operation lifecycle

Every mutating request must have a unique 32-byte proposal ID and one ledger row. HTTP 202 means **accepted for processing**, not committed. Each accepted operation must end in exactly one classified outcome:

- `COMMITTED` — successful mutation and durability contract satisfied;
- `REJECTED` — terminal, with a stable reason and no mutation;
- `FAILED` — terminal operational failure, with no ambiguous effect;
- `UNKNOWN` — harness or runtime could not establish the outcome; this fails a correctness campaign.

Timeout, missing response, blank JSON, missing sample, and parse failure are `UNKNOWN`, never zero or success.

## 3. Safety and topology boundary

### 3.1 Default test topology

Use one three-member cluster only:

- validator HTTP: `8090`, `8092`, `8094`;
- Aeron base port: `9000`;
- one local IPFS daemon;
- no simultaneous 3x2, 3x3, 5x3, or 5x3x3 campaign.

The preferred disposable runtime root is:

```text
~/oak-chain/single-cluster/3-node
```

The long-lived cluster observed while drafting this charter uses the legacy root:

```text
/Users/mhess/oak-chain
```

Never infer the live root from `single-cluster-3.env`. Every command must record and explicitly bind the intended root.

### 3.2 Current long-lived cluster rule

The legacy-root long-lived cluster is a read-only baseline until the user explicitly approves mutation. Do not run against it:

- `--fresh`;
- process signals or restarts;
- staircase suites;
- delete/GC campaigns;
- persistence sweeps;
- heavy, soak, ultra, or multi-node load profiles.

### 3.3 Risk classes

| Class | Name | Permitted behavior | Approval |
|---|---|---|---|
| A | Read-only | GETs, process metadata, logs, filesystem metadata, config, metrics | May run after root/provenance confirmation |
| B | Bounded mutation | Unique disposable namespace, 1–2 clients, ≤50 operations, no signals | Explicit target/root confirmation |
| C | Controlled fault | Preserve stores; one TERM/KILL/STOP/restart at a time | Explicit approval before each campaign |
| D | Destructive | `--fresh`, erase/stale follower, corruption, snapshot forcing, GC | Explicit approval and disposable root only |

Cleanup is recorded separately. Cleanup success can never turn a failed scenario into a pass.

## 4. Mac-safe resource policy

The limiting resource is the shared physical machine and disk, not request generation.

### 4.1 Default budgets

- one three-validator topology;
- 1 client normally, 2 only for ordering/backpressure tests;
- ≤50 operations for functional campaigns;
- ≤200 attempts for bounded pressure;
- no binary larger than the small fixture during consensus campaigns;
- no concurrent GC and write-pressure test;
- one injected fault at a time;
- stop generators before validators;
- preserve runtime state and evidence after failure.

Recommended JVM caps for disposable campaigns:

```text
-Xms256m -Xmx768m per validator
```

### 4.2 Abort conditions

Abort mutation, stop generators, and capture evidence when any condition occurs:

- two leaders in two consecutive one-second samples;
- no leader for more than 90 seconds;
- a write commits without quorum;
- committed content disappears;
- rejected content appears;
- strict logical digest mismatch after the scenario convergence deadline;
- unexpected validator exit or MediaDriver crash;
- any unplanned HTTP 5xx or transport failure;
- queue does not drain within 300 seconds after bounded traffic stops;
- free disk below 10 GiB or test growth above 5 GiB;
- combined validator RSS above 45% of host RAM for two minutes;
- swap growth above 1 GiB in five minutes;
- validator CPU above 600% for two minutes outside an intentional short burst;
- any OOM, `Too many open files`, fatal Aeron shutdown, or sustained thermal distress.

## 5. Run contract

Every scenario has explicit preconditions, actions, assertions, deadlines, resource budget, evidence, and cleanup. A formal runner must create an immutable run directory before the first action.

### 5.1 Manifest

Record:

- run/scenario IDs, risk class, deterministic seed, start/end UTC;
- runtime root, ports, PIDs, process start times;
- Git HEAD and dirty state for `jackrabbit-oak` and `oak-chain-infra`;
- JAR path, SHA-256, size, mtime, manifest, and source commit if available;
- Java, macOS, hardware/RAM, IPFS versions;
- sanitized JVM arguments and environment;
- `/v1/config/osgi`, `/sources`, `/delta`, `/coverage` from every node;
- resource limits and abort thresholds;
- exact invoked commands and approved fault actions.

Never capture tokens, private keys, keystore contents, secrets, or authorization headers.

### 5.2 Timeline and raw evidence

Record as append-only NDJSON/CSV:

- client monotonic invocation and response times;
- proposal ID, operation ID, HTTP status/body, path, wallet, content hash;
- every observed operation-state transition;
- leader, role, term, quorum, cluster time, and log-position timeline;
- fault signal/action and recovery timestamps;
- per-node health, consensus, Aeron, replication, queue, storage, and Prometheus samples;
- PID, CPU, RSS, thread, FD, and disk samples;
- logs, triage output, and triggered jstacks;
- canonical state JSON and strict/semantic digests;
- journal/TAR and queue/payload inventory when relevant;
- binary fixture and retrieved SHA-256 when relevant.

### 5.3 Assertion ledger

Every assertion is one row with:

```text
scenarioId | assertionId | expected | observed | PASS|FAIL|UNKNOWN | evidencePath | note
```

A scenario passes only if every required assertion is `PASS`. `UNKNOWN` fails the scenario. Warnings and optional diagnostics are clearly separated from required assertions.

## 6. Global deadlines

| Event | Hard deadline |
|---|---:|
| Initial election | 60 s |
| Leader replacement | 90 s |
| Normal accepted operation to terminal state | 90 s |
| Follower rejoin/catch-up | 90 s normal, 180 s hard crash |
| Cluster healthy after restoration | 120 s |
| Queue drain after bounded traffic | 300 s |
| Logical convergence after terminal operations | 60 s |
| Post-soak final drain | 30 min |

Record distributions as well as hard pass/fail. Until product SLOs are adopted, p50/p95/p99 are descriptive rather than release gates.

## 7. Scenario matrix

### Phase 0 — provenance, baseline, and observability

| ID | Risk | Preconditions and action | Required assertions | Budget/deadline |
|---|---|---|---|---|
| P0-01 Artifact provenance | A | Capture repos, JAR, process, runtime root, effective config | JAR/process/root identity complete; dirty files listed; no secret material | 2 min |
| P0-02 Process/topology map | A | Map PIDs, ports, Aeron dirs, stores, IPFS, OPS | Exactly 3 validator PIDs and expected listeners; no PID reuse ambiguity | 2 min |
| P0-03 Leader/quorum parity | A | Sample all health/consensus/Aeron surfaces together | Exactly one leader; all agree on leader URL, 3 members, quorum 2, reachable 3 | 60 s |
| P0-04 Observability contract | A | Compare JSON APIs, OPS, Prometheus, process and filesystem | Required fields present; contradictions classified; missing is UNKNOWN | 60 s |
| P0-05 Idle quietness | A | Observe a fault-free, write-free window | No elections/process exits; queues remain zero; bounded CPU/RSS/log slopes | 30 min |
| P0-06 Unit baseline | A | Run module/unit gates before packaging | Changed-path tests green; full-suite failures either fixed or explicitly baselined | 10 min |

#### P0 observability assertions

After rollout of the source fixes drafted with this charter:

- mock Beacon health reports `epochSource=local-clock` and `externalNetworkPolling=false`;
- no Beacon HTTP request or Beacon WARN/ERROR signature appears in mock mode;
- one process-owned Beacon client/poller is initialized per validator;
- Prometheus `oak_consensus_is_leader` equals API role on each node;
- Prometheus `oak_validators_reachable` equals the same scrape-window API count;
- follower lag is either a measured non-negative value or explicit `UNKNOWN`, never `-1` labeled unhealthy;
- follower term projection hydrates after leader discovery and is marked as synthesized/local until a native term source exists;
- leadership history separates wall-clock observation time and Aeron cluster time, and records the post-transition term;
- topology introspection reports node IDs `0/1/2`, self URL configured, and two peers per node;
- rate-limit source distinguishes defaults from explicit system/OSGi values and matches actual startup enforcement;
- segment byte gauge equals top-level `data*.tar` logical bytes, not Aeron sparse files or allocated disk;
- `/v1/head.committedHead` is JSON null when no committed head exists.

### Phase 1 — bounded functional correctness

Use one disposable namespace, one client, and at most 50 operations.

| ID | Risk | Action | Required assertions | Budget/deadline |
|---|---|---|---|---|
| F1-01 One write | B | Submit one valid write to leader | 202 only means accepted; operation reaches COMMITTED; exact value visible on all nodes | 1 op / 90 s |
| F1-02 CRUD surface | B | Writes, individual delete, subtree delete, namespace delete | Every accepted op terminal; expected model equals all nodes; deleted paths absent | ≤30 ops |
| F1-03 Redirect contract | B | Submit a write to each follower | 307/wrong-leader and correct Location; no duplicate operation | 2 attempts |
| F1-04 Rejections/no mutation | B | Low-rate malformed, unauthorized, wrong-owner requests | Expected 4xx/503; no operation/mutation/counter false increment | ≤20 attempts |
| F1-05 Duplicate proposal ID | B | Replay same proposal before/after terminal state | One logical effect or deterministic duplicate rejection; never two effects | 3 attempts |
| F1-06 Small binary/IPFS | B | Existing small fixture only | COMMITTED metadata on all nodes; pin/retrieval succeeds; SHA-256 identical | 1 binary |

### Phase 2 — ordering, linearizability, and convergence

| ID | Risk | Action | Required assertions | Budget/deadline |
|---|---|---|---|---|
| O2-01 Serialized history | B | Deterministic sequence of writes/deletes | Offline model admits history; final strict digest equals model on all nodes | 25 ops |
| O2-02 Seeded two-client history | B | 2 clients × ≤25 operations with fixed seed | Linearizable/model-valid history; one terminal outcome per proposal | ≤50 ops |
| O2-03 Same-wallet collision | B | Closely timed writes under same wallet/org/type | Distinct accepted proposals do not collide or overwrite silently | ≤20 ops |
| O2-04 Immediate post-commit reads | B | Read leader and followers immediately after COMMITTED | Read contract explicitly passes; any follower window measured, not hidden | ≤10 ops |
| O2-05 Recursive convergence | A/B | Export complete test namespace on each node | Strict digest equal; semantic digest diagnostic; physical heads recorded separately | 60 s |

The client history records monotonic invoke/return times. Only `COMMITTED` is modeled as a successful mutation. If A completes before B begins, later reads cannot omit A unless a committed ordered delete removes it.

### Phase 3 — single-member faults

Run on a disposable cluster, preserve stores, one fault at a time.

| ID | Risk | Action | Required assertions | Budget/deadline |
|---|---|---|---|---|
| S3-01 Follower TERM | C | Gracefully stop one follower, bounded writes, rejoin | Quorum/progress with 2; all writes terminal; follower catches up and digest matches | ≤10 ops / 90 s |
| S3-02 Follower KILL | C | Hard-kill one follower, bounded writes, restart | No committed loss; recovery ≤180 s; full digest match | ≤10 ops |
| S3-03 Follower STOP | C | Pause one follower briefly, resume | No false partition claim; queues bounded; follower converges | ≤10 ops |
| S3-04 Leader TERM | C | Graceful leader stop during quiet window | One new leader ≤90 s; old leader rejoins follower; history coherent | 1 fault |
| S3-05 Leader KILL/election writes | C | Kill leader around a small write schedule | Outcomes explainable; no double apply; committed writes preserved | ≤10 ops |
| S3-06 Warm failover loop | C | Repeat bounded leader failover | No session leak/reconnect loop; complete reconciliation each cycle | 2 cycles Mac default |

SIGSTOP/SIGKILL are process-fault tests, not proof of an Aeron network partition.

### Phase 4 — quorum envelope

| ID | Risk | Action | Required assertions | Budget/deadline |
|---|---|---|---|---|
| Q4-01 One member lost | C | Stop one member; submit one write | 2-member quorum commits; exact state on survivors and recovered member | 1 op |
| Q4-02 Two members lost | C | Stop two members; submit one write | No quorum; write cannot COMMIT; rejected path never appears | 1 attempt |
| Q4-03 Quorum recovery | C | Restore members; submit sentinel write | Exactly one leader, full quorum, progress restored, full convergence | 1 op / 120 s |

Any commit observed while fewer than two configured members participate is an immediate safety failure.

### Phase 5 — durability crash windows

Run only on a fresh disposable root with queue persistence enabled and effective settings captured.

| ID | Risk | Crash point | Required assertions | Budget |
|---|---|---|---|---|
| D5-01 Post-202 | C/D | Immediately after accepted response | Eventual terminal outcome or deterministic same-ID retry; no ambiguous silent loss | 1 op/fault |
| D5-02 Processing | C/D | Operation observed PROCESSING | Explainable recovery; no double apply; queue manifest/payload evidence retained | 1 op/fault |
| D5-03 Processed/durability pending | C/D | Source applied, durability not ACKED | Retry/recovery correct; COMMITTED not reported prematurely | 1 op/fault |
| D5-04 Post-COMMITTED | C/D | After durability ACKED | Mutation survives leader loss and all-three restart without `--fresh` | 1 op/fault |
| D5-05 Duplicate after crash | C/D | Retry same proposal ID after each window | Exactly one logical effect | 4 cases |

### Phase 6 — restart, catch-up, and snapshot recovery

| ID | Risk | Action | Required assertions | Deadline |
|---|---|---|---|---|
| R6-01 All-three graceful restart | C | Stop/start preserving all stores | All committed state and deletes survive; one leader/full quorum | 120 s |
| R6-02 All-three hard restart | C | Hard stop/start preserving stores | Same as above; no fresh state | 180 s |
| R6-03 Stale follower replay | C/D | Hold follower behind bounded history, restart | Catch-up completes; strict digest matches | 180 s |
| R6-04 Empty follower bootstrap | D | Erase one disposable follower only | Snapshot/bootstrap succeeds; complete state/delete preservation | 300 s |
| R6-05 Snapshot validation | D | Force snapshot-scale gap | External file inventory plus logical reopen validates restore; WARN-only validation is insufficient | 300 s |

### Phase 7 — bounded backpressure

Use intentionally small limits rather than brute force:

- `max_pending_messages`: 32–64;
- `backpressure_timeout_ms`: 1–2 s;
- hard pending cap: 128–256;
- payload spill cap: 64 MiB;
- 2 clients, ≤200 attempts, no large binaries.

| ID | Risk | Action | Required assertions | Deadline |
|---|---|---|---|---|
| B7-01 Governed overload | D | Bounded attempts against small caps | Overload is governed 429/503, never OOM/deadlock/generic 500 | traffic ≤2 min |
| B7-02 Accepted-op drain | D | Stop traffic and reconcile | Every accepted op terminal; all queue/overflow/persistence/spool counts baseline | 300 s |
| B7-03 Accounting integrity | D | Observe reconciliation counters | Accounting reconciliation never substitutes for operation/state proof | 300 s |

### Phase 8 — low-rate soak

Do not use the existing 20-client `04-soak-2h.sh` unchanged.

Default Mac soak:

- one client;
- one write every 5–15 seconds;
- 4 hours or ≤2,000 writes;
- 0–1% small binary mix;
- one unique namespace;
- no concurrent GC;
- health/role every 5 s, queues every 10 s, resources every 30 s;
- recursive digest every 15 minutes;
- 30-minute final drain/reconciliation.

Required assertions:

- no unexpected PID change or leader rotation;
- no fatal/OOM/FD/MediaDriver errors;
- every accepted operation terminal;
- final strict digest matches all nodes and expected model;
- no sustained RSS slope above 128 MiB/hour after first 30 minutes;
- FD slope below 5/hour;
- queues return to baseline;
- no unexpected WARN/ERROR signature after known mock Beacon noise is removed.

### Phase 9 — adversarial/protocol tests

Live HTTP tests remain low rate and bounded. Raw Aeron frame/message fuzzing belongs in unit/embedded tests, not the laptop cluster.

Required live matrix includes malformed wallet, signature, transaction hash, proposal ID, organization, ownership, duplicate ID, follower redirect, unknown leader, no quorum, ambiguous binary source, invalid CID policy, and CID service unavailable.

Fixed-seed protocol tests include short header, invalid block length, unknown template, missing fields, stale term, malformed batch, missing durability/GC/transaction fields, and ≤64 KiB frame corpus. Invalid input must never invoke application callbacks or escape as an uncaught exception.

### Deferred — real network partition

A process pause/kill is not a network partition. A true partition campaign remains deferred until the harness can isolate Aeron UDP paths without global macOS firewall changes, preferably through scoped user-space UDP proxies. HTTP reachability must be independently controllable because current quorum/reachability views include HTTP probes.

## 8. Canonical state exporter requirements

The strict exporter must recursively emit:

```json
{
  "path": "/...",
  "properties": [
    {"name": "...", "type": "...", "value": "canonical exact representation"}
  ],
  "children": ["recursively sorted by child name"]
}
```

Rules:

- stable UTF-8 and escaping;
- sorted child/property names;
- preserve property type and array order;
- exact binary/CID metadata representation;
- no timestamps added by the exporter;
- traversal failure is UNKNOWN/failure, not an omitted subtree;
- hash both canonical JSON and raw per-node export.

A second semantic report may isolate known volatile metadata, but semantic equality cannot override strict divergence.

## 9. Harness components to build

The charter should be implemented as composable tools, not one shell monolith:

1. `strict-preflight` — provenance, root binding, process/port map, leader/quorum parity.
2. `evidence-runner` — immutable run directory, manifest, timeline, assertion ledger.
3. `operation-client` — unique IDs, bounded retries, terminal reconciliation.
4. `state-exporter` — recursive canonical JSON and digest.
5. `history-checker` — deterministic expected model and linearizability/order validation.
6. `cluster-sampler` — synchronized API/Prometheus/process/resource snapshots.
7. `fault-controller` — one approved scoped fault, PID identity verification, recovery deadline.
8. `resource-guard` — threshold abort and evidence capture.
9. `reporter` — PASS/FAIL/UNKNOWN summary with evidence links.

Shell may orchestrate processes, but JSON handling, histories, and assertions should use a real parser and typed Python/Java models.

## 10. Existing harness disposition

| Existing surface | Disposition |
|---|---|
| `smoke/validator-api-smoke.sh` | Diagnostic only until strict failures propagate nonzero |
| `surfaces/proposal-surfaces-single-cluster.sh` | Useful bounded base, but destructive by default and incomplete operation/model reconciliation |
| stability Aeron scripts | Reuse fault mechanics; add assertion ledger, terminal reconciliation, and full digest |
| `integration/test-binary-upload.sh` | Reuse flow only after checksum/pin/retrieval false-green paths are fixed |
| load harness | Reuse generator only; HTTP 200/202 is not success without terminal reconciliation |
| benchmark gate | Performance diagnostic; not a consensus correctness gate |
| draft pause/rejoin scripts | Exploratory, never formal gates while generator failure is ignored |
| staircase | Destructive topology exercise; not a default Mac correctness gate |
| `ThreeValidatorConsensusIT` | Replace/repair stale routes and contracts before use |

## 11. Current implementation/readiness findings

### 11.1 Source hardening completed in this drafting pass

Pending build/restart validation, source changes now target:

- local clock-backed Beacon epochs in mock mode with no external Beacon traffic;
- one shared Beacon client per validator process;
- late-bound consensus state for Prometheus gauges;
- TAR-only logical segment-byte metrics;
- explicit UNKNOWN replication-lag semantics plus leader-state hydration;
- effective standalone topology introspection;
- truthful rate-limit provenance and mock-runner defaults;
- separate leadership wall time/cluster time and corrected transition term;
- null committed head instead of false latest-to-committed promotion.

The running legacy-root cluster still uses the old loaded JAR. It has not been restarted and remains the baseline for the observations that motivated these changes.

### 11.2 Unit baseline status observed while drafting

Changed-path regression set:

```text
190 tests, 0 failures, 0 errors
```

The complete current module suite is not green:

```text
1,257 tests, 2 failures, 6 errors
```

Seven failures/errors reproduce in a focused run and are outside the files changed by this hardening pass:

- four `ServerInfrastructureInitializerTest` null-server errors;
- one `GlobalStoreServerStartupValidationTest` expected-exception mismatch;
- two `ProposalQueueIntegrationTest` stale callback-overload assertions.

One `AeronInternalIngressClientManagerTest` error appears order-dependent and passes when isolated.

A formal cluster campaign must not hide this baseline. Either fix these tests or establish a reviewed, evidence-backed quarantine before claiming a release gate is green.

## 12. Execution ladder

Run in this order, stopping on the first failed gate:

1. Review and approve this charter.
2. Fix/quarantine the module baseline failures.
3. Implement strict preflight, evidence bundle, and state exporter.
4. Validate source hardening in an embedded/unit context.
5. Build a provenance-stamped JAR.
6. Start a fresh disposable three-node cluster under the isolated root.
7. Run Phase 0.
8. Run Phase 1 with one write, then full bounded functional campaign.
9. Run Phase 2 ordering/convergence.
10. Request approval for each Phase 3/4 fault campaign.
11. Request separate destructive approval for Phases 5–7.
12. Run soak only after all shorter gates are green and resource slopes are understood.
13. Preserve and review final evidence before any “consensus validated” claim.

## 13. Exit criteria

The local mock suite supports a strong consensus-correctness claim only when:

- every required scenario is PASS with no UNKNOWN assertions;
- no accepted operation is unreconciled;
- no committed effect is lost across tested boundaries;
- no no-quorum mutation commits;
- strict logical digests match every validator and the expected model;
- failover/recovery deadlines pass without hidden process replacement;
- observability surfaces satisfy their cross-contract assertions;
- resource budgets and abort guards hold;
- evidence is complete, immutable, and reviewable;
- limitations are stated: mock auth/signature behavior, single-host shared-fate, no true network partition, and no byte-identical Segment guarantee.
