# Oak Chain Infra

Mode-oriented infrastructure repository for Oak Chain operations.

## Layout

- `modes/mock/`
  - Local validator lifecycle and IPFS daemon workflows.
  - Load-test harness for local consensus validation.
  - Intentionally excludes Sling starter, EDS site, and SDK build orchestration.
- `modes/sepolia/`
  - AWS deployment stub for upcoming Sepolia pivot.
- `modes/mainnet/`
  - AWS deployment stub for production topology.

## Current Status

- `mock`: active and populated from legacy `blockchain-aem-infra` local-development/load-test scripts.
- `sepolia`: stub only.
- `mainnet`: stub only.

## Migration Note

This repo is the successor to local infra automation previously kept in `blockchain-aem-infra`.
