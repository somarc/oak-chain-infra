# Validator Tests (Sepolia Mode)

Focused validation scripts for local validator clusters.

## Available Scripts

- `validator-api-smoke.sh`
  - Probes validator API/cluster endpoints across nodes.
- `test-binary-upload.sh`
  - Exercises binary/IPFS upload flow.

## Prerequisites

- Validator cluster running (see `../lifecycle/start-cluster.sh`).
- `curl` + `python3` installed.
- `jq` optional for richer output parsing.

## Usage

```bash
# API/cluster smoke
./validator-api-smoke.sh

# Binary/IPFS flow
./test-binary-upload.sh
```
