# Oak Chain Infra

Mode-oriented infrastructure repository for Oak Chain operations.

## `oak-chain` CLI

This repo now carries the v0 internal operator CLI for Oak Chain validators.

It is intended for:

- fast reads against a single seed validator and its discovered peers
- single-cluster operator inspection for mock, sepolia, and mainnet environments
- single-cluster mock-local lifecycle and validation wrappers
- a separate `lab` namespace for local topology and staircase testing
- Codex and operator workflows that need deterministic JSON output

Quick start:

```bash
cd /Users/mhess/aem/aem-code/OAK/oak-chain-infra
npm link

oak-chain cluster snapshot --json
oak-chain peer list
oak-chain peer probe
oak-chain proposal status <proposalId> --base-url http://127.0.0.1:8090
oak-chain doctor
oak-chain ops board

oak-chain mock up -- --fresh --build
oak-chain mock console
oak-chain mock campaign run p0-preflight
oak-chain mock verify smoke
oak-chain lab 3x2 up -- --fresh
oak-chain lab verify surfaces-3x2
```

Useful defaults:

- `--profile mock-local`
- `--profile sepolia-local`
- `--profile sepolia-readonly`
- `--profile mainnet-readonly`
- `--profile prod-readonly`
- `--peer` to restrict peer fanout to a single discovered validator
- `--dry-run` to inspect wrapped script invocations
- `--ops-url` to point the read-only TUI at a governed OPS adapter
- `--once` to render one board snapshot for terminals, CI evidence, or piping
- `--field` and `--raw` for narrow machine-readable output

The CLI deliberately stays thin:

- validator source APIs remain owned by `jackrabbit-oak`
- browser-facing `/ops/v1/*` remains owned by `oak-chain-edge-worker`
- top-level `oak-chain` remains single-cluster aware
- `oak-chain mock ...` stays single-cluster to preserve parity with sepolia and mainnet operating shape
- topology bring-up and staircase work live under `oak-chain lab ...`
- local script orchestration remains owned by `oak-chain-infra`

### Cluster operations board

Run the read-only-first terminal board against the local OPS proxy:

```bash
oak-chain ops board
```

Use `q` to quit and `r` to refresh immediately. For a remote environment, pass an OPS adapter URL and disable the mock-local log adapter:

```bash
oak-chain ops board \
  --ops-url https://ops.example.net \
  --profile prod-readonly \
  --no-local-logs
```

Colour is enabled automatically in an interactive terminal. Use `--color` to preserve it in one-shot output or `--no-color`/`NO_COLOR=1` for plain text.

The lifecycle scripts remain the recoverable control plane; the TUI is a view over governed telemetry rather than a reimplementation of startup logic. See [`docs/OPS-TUI-ARCHITECTURE.md`](docs/OPS-TUI-ARCHITECTURE.md) for the structured lifecycle-event contract and production roadmap.

### Consensus campaigns

`oak-chain mock campaign run <name>` runs a campaign from `modes/mock/campaigns/`. Each run produces an evidence bundle (manifest, operation ledger, samples, and an assertion ledger with PASS / FAIL / UNKNOWN), following `modes/mock/validators/tests/CONSENSUS-TEST-CHARTER.md`. Start with `p0-preflight`, which is read-only. Writes need `--allow-class B`, and the long-lived `~/oak-chain` root also needs `--allow-live-root`. See [`modes/mock/campaigns/README.md`](modes/mock/campaigns/README.md).

### Valid transactions

Every write and delete that the scripts, load tests and harness send is built by one builder, `oak-chain tx key|write|delete|verify` (`src/tx.mjs`; shell helpers in `modes/mock/lib/oak-tx.sh`). Each one is valid under the runtime's contract ([`modes/mock/TRANSACTION-CONTRACT.md`](modes/mock/TRANSACTION-CONTRACT.md)): it is signed by `walletAddress` (deterministic test keys, listed in `modes/mock/lib/test-wallets.tsv`) over exactly the message, or the `contentPath` for deletes. In mock mode `ethereumTxHash` is the `proposalId`; Sepolia scripts require a real `payWrite` settlement from env. `paymentTier` is no longer sent anywhere: the runtime does not read it, because the tier comes from the settlement proof.

### Mock cluster console

Start, stop and fault-inject the local mock cluster from one screen:

```bash
oak-chain mock console
# or, from modes/mock/validators/lifecycle:
./console.sh
```

The header always shows the runtime root being controlled. Members show process and HTTP state, role, uptime and each node's Aeron view, with a quorum summary above them.

| Key | Action | Runs |
|---|---|---|
| `s` | start the cluster (`f` toggles `--fresh`, `b` toggles `--build`; fresh asks first) | `start-cluster.sh` |
| `x` | stop everything (asks first) | `stop-cluster.sh` |
| `↑↓` / `0-4` | select a member | — |
| `u` / `t` / `r` | start / graceful stop / restart the member | `member.sh start\|stop\|restart N` |
| `k` | hard-kill the member, a simulated crash (asks first) | `member.sh kill N` |
| `l` | switch the pane between operation output and the member's log | — |
| `q` | quit; the cluster keeps running | — |

Stopping or restarting a member that would leave fewer than a majority running asks for confirmation first. Only one operation runs at a time.

The console never signals processes itself: every action is one of the lifecycle scripts, which stay usable directly for recovery. Use `--once` (or a non-interactive stdout) for a plain status snapshot, and `--runtime-root PATH` to point at another runtime root. Resizing between 3 and 5 members is deliberately not offered here: Aeron membership is static, so resizing means a fresh re-form.

## Layout

- `fixtures/binaries/`
  - Shared binary payloads for validator tests and load harnesses.
- `modes/mock/`
  - Local validator lifecycle and IPFS daemon workflows.
  - Load-test harness for local consensus validation.
  - Intentionally excludes Sling starter, EDS site, and SDK build orchestration.
- `modes/sepolia/`
  - Local validator lifecycle scripts for Sepolia + AWS deployment stub.
- `modes/mainnet/`
  - AWS deployment stub for production topology.
  - Includes imported legacy Elastic Beanstalk/EFS Terraform starter material
    under `modes/mainnet/aws/legacy/oak-segment-consensus/`.

## Current Status

- `mock`: active and populated from legacy `blockchain-aem-infra` local-development/load-test scripts.
  - CLI parity target is single-cluster local operation
  - uses explicit config surfaces for `OAK_CLUSTER_NAME`, `CLUSTER_RUNTIME_ROOT`, `OAK_VALIDATOR_HTTP_BASE_PORT`, `AERON_DIR_BASE`, and `AERON_CLUSTER_BASE_PORT`
  - CLI `lab` namespace wraps the local `3x2`, staircase, and related testing flows that still live under `modes/mock/validators/...`
- `sepolia`: local validator lifecycle automation available; AWS topology remains stub.
- `mainnet`: stub plus imported legacy standalone AWS Terraform skeleton.

## Migration Note

This repo is the successor to local infra automation previously kept in `blockchain-aem-infra`.
