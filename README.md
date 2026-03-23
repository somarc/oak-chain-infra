# Oak Chain Infra

Mode-oriented infrastructure repository for Oak Chain operations.

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
  - includes single-cluster lifecycle plus local `3x2` sharding topology wrappers
  - uses explicit config surfaces for `OAK_CLUSTER_NAME`, `CLUSTER_RUNTIME_ROOT`, `OAK_VALIDATOR_HTTP_BASE_PORT`, `AERON_DIR_BASE`, and `AERON_CLUSTER_BASE_PORT`
  - current single-host `3x2` proof is partially blocked until `jackrabbit-oak`
    honors a configurable Aeron port base instead of hardcoding `9000`
- `sepolia`: local validator lifecycle automation available; AWS topology remains stub.
- `mainnet`: stub plus imported legacy standalone AWS Terraform skeleton.

## Migration Note

This repo is the successor to local infra automation previously kept in `blockchain-aem-infra`.
