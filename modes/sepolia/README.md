# Sepolia Mode

Sepolia mode supports local validator lifecycle automation with real Sepolia RPC + contract wiring.

## Included

- `validators/`
  - Startup/teardown scripts for local validator cluster (same operational pattern as mock mode).
  - Config pack with `sepolia.env` and `sepolia.env.example`.
  - Monitoring and smoke-test helpers mirrored from mock mode.
- `aws/`
  - Still a topology stub for future cloud deployment artifacts.

## Quick Start

1. Set Sepolia config in `validators/config/sepolia.env` (or pass `--config`).
2. Ensure `OAK_BLOCKCHAIN_RPC_URL` and `OAK_BLOCKCHAIN_CONTRACT_ADDRESS` are set.
3. Start cluster:
   - `./validators/lifecycle/start-cluster.sh --build --fresh`
