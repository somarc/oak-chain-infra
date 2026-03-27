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

oak-chain mock up -- --fresh --build
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
- `--field` and `--raw` for narrow machine-readable output

The CLI deliberately stays thin:

- validator source APIs remain owned by `jackrabbit-oak`
- browser-facing `/ops/v1/*` remains owned by `oak-chain-edge-worker`
- top-level `oak-chain` remains single-cluster aware
- `oak-chain mock ...` stays single-cluster to preserve parity with sepolia and mainnet operating shape
- topology bring-up and staircase work live under `oak-chain lab ...`
- local script orchestration remains owned by `oak-chain-infra`

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
