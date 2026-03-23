# Validator Tests (Mock Mode)

Focused validation scripts for local validator clusters.

## Available Scripts

- `validator-api-smoke.sh`
  - Probes validator API/cluster endpoints across nodes.
- `sharding-3x2-smoke.sh`
  - Probes both local clusters for sharding health and authoritative-vs-foreign write routing.
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

# 3x2 sharding smoke
./sharding-3x2-smoke.sh

# Binary/IPFS flow
./test-binary-upload.sh
```
