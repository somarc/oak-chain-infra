# Consensus campaigns

These are campaign definitions for the consensus test harness (`src/harness/`). It implements charter (`validators/tests/CONSENSUS-TEST-CHARTER.md`) phases 0–4 and 6 and the §9 components: preflight, evidence runner, operation client, state exporter, cluster sampler, fault controller and reporter.

Each campaign is data: an id, a risk class (§3.3), the charter scenario IDs it covers, the scenario it runs, and that scenario's parameters. The scenarios themselves live in `src/harness/scenarios.mjs` (classes A and B) and `src/harness/fault-scenarios.mjs` (class C and F1-05).

```bash
oak-chain mock campaign list
oak-chain mock campaign run p0-preflight                                            # class A, read-only
oak-chain mock campaign run reconcile-accepted --accepted <load-run>/<name>-accepted-<ts>   # class A
oak-chain mock campaign run f1-one-write --allow-class B [--allow-live-root]         # class B, 2 writes
oak-chain mock campaign run f1-mixed-batch --allow-class B [--allow-live-root]       # class B, 21 ops
```

| Campaign | Class | What it proves |
|---|---|---|
| `p0-preflight` | A | **Provenance:** jar SHA-256, repo HEADs and dirty state, every process started after the jar was built, OSGi config captured. **Process identity:** each pid file names the process serving its port. **Leader and quorum:** one agreed leader across rounds, full membership, reachability and quorum. **Role parity:** the role matches across `/health`, consensus and Aeron, and Prometheus agrees. **Idle check:** a short idle window. |
| `f1-one-write` | B | **F1-01:** one plain write is accepted, then COMMITTED (durability ACKED). It is present on every validator, with the exact submitted values, and is strictly identical across nodes. **F1-01b:** the same checks for a value containing quotes, backslashes, unicode and form-reserved characters. |
| `f1-mixed-batch` | B | **F1-02 (packing):** one registered wallet commits 6 setup writes, then fires 3 rounds of write, delete, write, delete, write concurrently at the leader so they share a packing window. In Oak a delete is an append without the node, so packing is legitimate; the outcome must not depend on it. Every committed delete's node is absent from the head (404) on every validator, and every burst write holds exactly its submitted values. The API does not expose batch membership, so the end state is asserted either way. `--rounds`, `--terminal-seconds` and `--convergence-seconds` override the parameters. |
| `reconcile-accepted` | A | Every write a load run reported as accepted (from `CAPTURE_WRITE_ACCEPTS=true`) reached a terminal outcome. Each one is present on every validator, carries the right proposal identity, and is strictly identical across nodes. |
| `f1-duplicate-proposal` | B | **F1-05:** a committed write is resent byte for byte (same proposalId and signature), and a second write is resent while still in flight. Each proposal must leave exactly one node on every validator. A write's node name embeds the leader's clock, so a second effect would land at a new path; the harness counts nodes under the parent that end with the proposal prefix. |
| `o2-convergence` | A | **O2-05:** the strict typed state digest of `/` (hidden nodes included) is identical on every validator. |
| `s3-follower-term` / `s3-follower-kill` | C | **S3-01/02:** one follower is stopped (SIGTERM, no escalation) or SIGKILLed. Five writes commit with the remaining majority, the follower restarts and catches up, every value is exact on all members, and the digests match. |
| `s3-leader-term` | C | **S3-04:** after three committed writes the leader is stopped in a quiet window. One new leader within 90 s, the writes are preserved, and the old leader rejoins as a follower. |
| `s3-leader-kill` | C | **S3-05, D5-05:** six writes are fired at the leader, which is SIGKILLed as soon as they are accepted. The new leader cannot report operations the old one accepted (status lives in leader memory), so each is resolved from state: on every survivor (APPLIED), on none (ABSENT), or on some (DIVERGENT, always a failure). Every in-flight proposal is then resent with the same proposalId: ABSENT ones must commit, and none may end with two nodes. |
| `q4-quorum-envelope` | C | **Q4-01/02/03:** with followers stopped down to a majority a write commits; one more stopped and a write is refused or never commits, and its path is never readable; with every member back a sentinel write commits and the no-quorum write ends on every member or on none. |
| `r6-restart-graceful` / `r6-restart-hard` | C | **R6-01/02:** writes and a signed delete commit, every member is stopped (SIGTERM) or SIGKILLed and restarted with its store. Values are exact, the delete holds, and the strict digest after the restart equals the digest before it. |

**Rules**
- Every run writes an evidence bundle, `<runtime-root>/runs/<run-id>/`, before its first action:
  - `manifest.json`: provenance, target, approvals and parameters;
  - `timeline.ndjson`, `ledger.ndjson` and `samples.ndjson`;
  - `assertions.tsv`: the charter §5.3 columns plus `kind`;
  - `summary.json` and `report.md`.
- A run passes only if every *required* assertion is PASS; `UNKNOWN` fails it. *Diagnostic* rows are reported but never decide the result.
- Class B and above require `--allow-class`. The long-lived legacy root (`~/oak-chain`) also requires `--allow-live-root` (charter §3.2) for class B, and never accepts class C: faults run only against a disposable root. Class D is not available yet.
- Faults (class C) go through `lifecycle/member.sh` only (`src/harness/faults.mjs`): it checks that the pid's command line names this root's store, never escalates a graceful stop to SIGKILL, and the harness never sets `OAK_ALLOW_LIVE_ROOT`. Every fault scenario starts only on a settled cluster (all members up, one agreed leader) and must leave it settled. A cluster whose launch record has a watchdog restarting members is not a valid target: launch with `--no-watchdog`.
- A 202 is "accepted", never "committed". Operation status lives on the leader (`/v1/ops/operations/{id}`), and the harness re-discovers the leader on every poll.
- `/api/explore` is still used for per-write value checks. Convergence is judged by the strict exporter (`tools/state-exporter/StateExporter.java`, `src/harness/exporter.mjs`): it opens each validator read-only over its HTTP segment store (the same path federation mounts use), walks `/` with Oak types, array order and hidden nodes, and hashes a canonical JSON (charter §8). External binaries are identified by blob id: the read-only store has no BlobStore, so their bytes are not re-hashed and each one is listed in `unreadableBinaries`.

## Suites

A suite runs an ordered list of campaigns against one target into one directory with one report:

```bash
oak-chain mock campaign suites
oak-chain mock campaign suite rebaseline --runtime-root ~/oak-chain-charter/rebaseline --allow-class B,C
```

- Every campaign's risk class is authorized before the first action.
- Output: `<runs-dir>/suite-<id>-<stamp>/` with each campaign's own run directory inside, plus `manifest.json` (jar and provenance), `gc.json` (GC status on every member before and after), `summary.json` and `report.md`. The report lists every campaign, the ones not run, and each failing or unknown required assertion.
- After each class C campaign the cluster must settle within `--recovery-seconds` (default 180); otherwise the remaining campaigns are not run and the suite fails.
- A suite passes only if every campaign ran and passed.

`rebaseline` covers charter phases 0–4 and 6 on a fresh disposable cluster. Launch one with a pinned jar (ports chosen to stay clear of the default 8090 cluster):

```bash
R=~/oak-chain-charter/rebaseline
CLUSTER_RUNTIME_ROOT=$R PID_DIR=$R/pids LOG_DIR=$R/logs CLUSTER_WALLET_FILE=$R/cluster-keystore.properties \
AERON_DIR_BASE=$R/aeron-media OAK_CLUSTER_NAME=charter-rebaseline OAK_VALIDATOR_HTTP_BASE_PORT=8490 \
AERON_CLUSTER_BASE_PORT=9400 OPS_PROXY_PORT=8798 AUTO_START_IPFS=false \
OAK_CONSENSUS_JAR=/abs/path/oak-segment-consensus-<commit>.jar \
  modes/mock/validators/lifecycle/start-cluster.sh --fresh --no-watchdog --no-load-observer --wait-seconds 180
```

Provenance names the jar from the launch record and, when `<jar>.provenance` exists (`source=<commit> dirtyFiles=<n> branch=<b>`), the jackrabbit-oak commit it was built from.
