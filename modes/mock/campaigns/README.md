# Consensus campaigns

These are campaign definitions for the consensus test harness (`src/harness/`). It implements the first slice of `validators/tests/CONSENSUS-TEST-CHARTER.md` §9.

Each campaign is data: an id, a risk class (§3.3), the charter scenario IDs it covers, the scenario it runs, and that scenario's parameters. The scenarios themselves live in `src/harness/scenarios.mjs`.

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

**Rules**
- Every run writes an evidence bundle, `<runtime-root>/runs/<run-id>/`, before its first action:
  - `manifest.json`: provenance, target, approvals and parameters;
  - `timeline.ndjson`, `ledger.ndjson` and `samples.ndjson`;
  - `assertions.tsv`: the charter §5.3 columns plus `kind`;
  - `summary.json` and `report.md`.
- A run passes only if every *required* assertion is PASS; `UNKNOWN` fails it. *Diagnostic* rows are reported but never decide the result.
- Class B and above require `--allow-class`. The long-lived legacy root (`~/oak-chain`) also requires `--allow-live-root` (charter §3.2). Classes C and D are not available yet.
- A 202 is "accepted", never "committed". Operation status lives on the leader (`/v1/ops/operations/{id}`), and the harness re-discovers the leader on every poll.
- `/api/explore` is an interim reader. It loses information (types dropped, arrays coerced), so it is not the strict exporter the charter requires in §8.
