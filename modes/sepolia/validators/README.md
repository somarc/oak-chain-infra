# Sepolia Validators

Validator-only local operations for Oak Chain Sepolia mode.

## Scope

- Starts/stops local `oak-segment-consensus` validator nodes.
- Assumes IPFS daemon is managed locally (`ipfs daemon`).
- Excludes Sling starter, EDS startup, and SDK build orchestration.

## Key Scripts

- `lifecycle/start-cluster.sh`
  - Launches validator nodes 0/1/2 in background.
  - Optional `--build` compiles `oak-segment-consensus` + `oak-segment-agentic` before launch.
  - Loads `config/sepolia.env` by default (`--config` to override).
  - Requires `OAK_BLOCKCHAIN_RPC_URL` + `OAK_BLOCKCHAIN_CONTRACT_ADDRESS`.
  - Waits for IPFS API readiness before launching validators.
  - Auto-starts IPFS daemon by default when API is unavailable (`AUTO_START_IPFS=true`).
  - Starts validator failure watchdog by default (`ENABLE_WATCHDOG=true`, `--no-watchdog` to disable).
  - Also starts OPS proxy adapter from `oak-chain-edge-worker`:
    - `OPS_MOCK_MODE=proxy OPS_UPSTREAM_BASE=http://127.0.0.1:8090 node src/ops-api-worker.mjs`
- `lifecycle/stop-cluster.sh`
  - Stops validator nodes 0/1/2 and OPS proxy using PID files.
  - Stops validator failure watchdog.
- `lifecycle/status-cluster.sh`
  - Checks validator `/health` endpoints, IPFS daemon presence, and OPS proxy `/ops/v1/overview`.
  - Includes watchdog status.
- `debug/run-validator-node.sh`
  - Runs one validator node directly for focused debugging.
- `monitoring/validator-failure-watchdog.sh`
  - Polls validator health and captures post-mortem bundles when a validator transitions from UP to DOWN.
  - Post-mortem output path:
    - `~/oak-chain/postmortem/validator-<node>-<timestamp>/`
  - Captures status/API/process evidence and recent logs to preserve root-cause clues.
- `monitoring/triage-validator-logs.sh`
  - Fast forensic summary across validator logs (IPFS failures, standby mismatch loop, Aeron retries, rate-limit pressure, queue stress, fatal/exception events).
  - Writes a timestamped report to:
    - `~/oak-chain/logs/validator-triage-<timestamp>.txt`
  - Useful right after load tests or cluster incidents.

## Config

- `config/sepolia.env`
- `config/sepolia.env.example`
- `config/ipfs.env`

## Smoke Validation

- `tests/validator-api-smoke.sh`

## OPS Proxy Environment Overrides

- `OPS_EDGE_WORKER_DIR` (default: `<OAK>/oak-chain-edge-worker`)
- `OPS_DASHBOARD_DIR` (legacy compatibility alias for `OPS_EDGE_WORKER_DIR`)
- `OPS_PROXY_MODE` (default: `proxy`)
- `OPS_PROXY_UPSTREAM` (default: `http://127.0.0.1:8090`)
- `OPS_PROXY_PORT` (default: `8787`)
- `IPFS_API_HTTP` (default: `http://127.0.0.1:5001`)
- `IPFS_READY_TIMEOUT_SECONDS` (default: `30`)
- `AUTO_START_IPFS` (default: `true`)
- `IPFS_DAEMON_LOG_FILE` (default: `$HOME/oak-chain/logs/ipfs-daemon.log`)
- `OAK_MOCK_EPOCH_DURATION_SECONDS` (default: `300`)
- `ENABLE_WATCHDOG` (default: `true`)
- `WATCHDOG_INTERVAL_SECONDS` (default: `5`)
