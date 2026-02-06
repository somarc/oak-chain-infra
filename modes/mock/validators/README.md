# Mock Validators

Validator-only local operations for Oak Chain mock mode.

## Scope

- Starts/stops local `oak-segment-consensus` validator nodes.
- Assumes IPFS daemon is managed locally (`ipfs daemon`).
- Excludes Sling starter, EDS startup, and SDK build orchestration.

## Key Scripts

- `lifecycle/start-cluster.sh`
  - Launches validator nodes 0/1/2 in background.
- `lifecycle/stop-cluster.sh`
  - Stops validator nodes 0/1/2 using PID files.
- `lifecycle/status-cluster.sh`
  - Checks validator `/health` endpoints and IPFS daemon presence.
- `debug/run-validator-node.sh`
  - Runs one validator node directly for focused debugging.

## Config

- `config/mock.env`
- `config/ipfs.env`

## Smoke Validation

- `tests/validator-api-smoke.sh`
