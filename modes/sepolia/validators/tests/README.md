# Validator Tests (Sepolia Mode)

Focused validation scripts for local validator clusters.

## Available Scripts

- `validator-api-smoke.sh`
  - Probes validator API/cluster endpoints across nodes.
- `test-binary-upload.sh`
  - Exercises binary/IPFS upload flow with a chain-backed, signed write.
  - Requires a real settlement from env and fails if any is missing:
    `PROPOSAL_ID` (the id passed to `ValidatorPaymentV5.payWrite`), `TX_HASH`
    (the confirmed `payWrite` transaction hash) and `OAK_TEST_PRIVATE_KEY` (the
    paying wallet's key, which signs the write via `oak-chain tx write --key`).
    Nothing is invented; see `../../../mock/TRANSACTION-CONTRACT.md`.

## Prerequisites

- Validator cluster running (see `../lifecycle/start-cluster.sh`).
- `curl` + `python3` installed.
- `node` (20+, with this repo's `npm install`) and `jq` for `test-binary-upload.sh`.

## Usage

```bash
# API/cluster smoke
./validator-api-smoke.sh

# Binary/IPFS flow (after a real payWrite from the signing wallet)
PROPOSAL_ID=0x... TX_HASH=0x... OAK_TEST_PRIVATE_KEY=0x... ./test-binary-upload.sh
```
