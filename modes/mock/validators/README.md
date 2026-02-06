# Mock Validators

Validator-only local operations for Oak Chain mock mode.

## Scope

- Starts/stops local `oak-segment-consensus` validator nodes.
- Assumes IPFS daemon is managed locally (`ipfs daemon`).
- Excludes Sling starter, EDS startup, and SDK build orchestration.

## Key Scripts

- `lifecycle/start-cluster.sh`
  - Launches validator nodes 0/1/2 in background.
  - Also starts OPS proxy adapter from `oak-chain-edge-worker`:
    - `OPS_MOCK_MODE=proxy OPS_UPSTREAM_BASE=http://127.0.0.1:8090 node src/ops-api-worker.mjs`
- `lifecycle/stop-cluster.sh`
  - Stops validator nodes 0/1/2 and OPS proxy using PID files.
- `lifecycle/status-cluster.sh`
  - Checks validator `/health` endpoints, IPFS daemon presence, and OPS proxy `/ops/v1/overview`.
- `debug/run-validator-node.sh`
  - Runs one validator node directly for focused debugging.

## Config

- `config/mock.env`
- `config/ipfs.env`

## Smoke Validation

- `tests/validator-api-smoke.sh`

## OPS Proxy Environment Overrides

- `OPS_EDGE_WORKER_DIR` (default: `<OAK>/oak-chain-edge-worker`)
- `OPS_DASHBOARD_DIR` (legacy compatibility alias for `OPS_EDGE_WORKER_DIR`)
- `OPS_PROXY_MODE` (default: `proxy`)
- `OPS_PROXY_UPSTREAM` (default: `http://127.0.0.1:8090`)
- `OPS_PROXY_PORT` (default: `8787`)
