# Mock Validators

Validator-only local operations for Oak Chain mock mode.

## Scope

- Starts/stops local `oak-segment-consensus` validator nodes.
- Assumes IPFS daemon is managed locally (`ipfs daemon`).
- Excludes Sling starter, EDS startup, and SDK build orchestration.

## Key Scripts

- `lifecycle/start-cluster.sh`
  - Launches validator nodes 0/1/2 in background.
  - Optional `--build` compiles `oak-segment-consensus` + `oak-segment-agentic` before launch.
  - Optional `--mock-epoch-seconds N` sets synthetic mock epoch duration (default 300s).
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
- `lifecycle/start-3x2.sh`
  - Starts two separate 3-node clusters for local sharding proof.
  - Reuses `start-cluster.sh` twice with scoped runtime roots, non-overlapping ports, and inverse shard ownership.
  - Disables watchdog/load-observer by default for the dual-cluster topology.
  - Reads shared cluster defaults from `config/3x2-common.env` and per-cluster overrides from `config/3x2-cluster-a.env` / `config/3x2-cluster-b.env`.
- `lifecycle/stop-3x2.sh`
  - Stops the local dual-cluster topology cleanly, cluster B first then cluster A.
- `lifecycle/status-3x2.sh`
  - Shows health and sharding posture for both local clusters.
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

- `config/mock.env`
- `config/ipfs.env`
- `config/3x2-common.env`
- `config/3x2-cluster-a.env`
- `config/3x2-cluster-b.env`

## Smoke Validation

- `tests/validator-api-smoke.sh`
- `tests/sharding-3x2-smoke.sh`

## Troubleshooting

- `TROUBLESHOOTING.md`
  - captures the `2026-03-22` local `3x2` Aeron findings
  - explains why MediaDriver directory isolation and Aeron transport port
    isolation are separate problems
  - documents the current single-host blocker: `oak-segment-consensus` still
    hardcodes Aeron topology around port base `9000`

## OPS Proxy Environment Overrides

- `OPS_EDGE_WORKER_DIR` (default: `<OAK>/oak-chain-edge-worker`)
- `OPS_DASHBOARD_DIR` (legacy compatibility alias for `OPS_EDGE_WORKER_DIR`)
- `OPS_PROXY_MODE` (default: `proxy`)
- `OPS_PROXY_UPSTREAM` (default: `http://127.0.0.1:8090`)
- `OPS_PROXY_PORT` (default: `8787`)
- `IPFS_API_HTTP` (default: `http://127.0.0.1:5001`)
- `IPFS_GATEWAY_BASE` (default: `http://127.0.0.1:8099/ipfs/`)
- `IPFS_LOCAL_GATEWAY_BASE` (default: `http://127.0.0.1:8099/ipfs/`)
- `IPFS_READY_TIMEOUT_SECONDS` (default: `30`)
- `AUTO_START_IPFS` (default: `true`)
- `IPFS_DAEMON_LOG_FILE` (default: `$HOME/oak-chain/logs/ipfs-daemon.log`)
- `OAK_MOCK_EPOCH_DURATION_SECONDS` (default: `300`)
- `ENABLE_WATCHDOG` (default: `true`)
- `WATCHDOG_INTERVAL_SECONDS` (default: `5`)
- `CLUSTER_RUNTIME_ROOT` (default: `$HOME/oak-chain`)
- `OAK_CLUSTER_NAME` (default: `single-cluster`)
- `OAK_VALIDATOR_HTTP_BASE_PORT` (default: `8090`)
- `OAK_VALIDATOR_HTTP_PORT_STEP` (default: `2`)
- `AERON_CLUSTER_BASE_PORT` (default: `9000`)
- `AERON_DIR_BASE` (default: `$CLUSTER_RUNTIME_ROOT/validator-N/aeron-media`)
- `AERON_GLOBAL_TMP_CLEANUP` (default: `false`; keep it false for `3x2`)
- `EXTRA_JAVA_OPTS` (used by 3x2 configs to turn on sharding JVM flags)
