# Mock Validators

Validator-only local operations for Oak Chain mock mode.

## Scope

- Starts/stops local `oak-segment-consensus` validator nodes.
- Assumes IPFS daemon is managed locally (`ipfs daemon`).
- Excludes Sling starter, EDS startup, and SDK build orchestration.

## Key Scripts

- `lifecycle/start-cluster.sh`
  - Launches validator nodes 0/1/2 in background.
  - Optional `--build` compiles `oak-segment-consensus` and any optional validator-side modules present in the current `jackrabbit-oak` branch before launch.
  - Optional `--mock-epoch-seconds N` sets mock-mode GC epoch duration (default 300s); Beacon telemetry stays local and follows the Sepolia clock shape.
  - Waits for IPFS API readiness before launching validators.
  - Writes `$PID_DIR/cluster-launch.env` (size, ports, Aeron dirs, `EXTRA_JAVA_OPTS`) so single members can later be restarted with identical membership and sharding flags. One `KEY=VALUE` per line, value verbatim after the first `=`, never sourced (`lifecycle/lib/launch-record.sh`).
  - Auto-starts IPFS daemon by default when API is unavailable (`AUTO_START_IPFS=true`).
  - Starts validator failure watchdog by default (`ENABLE_WATCHDOG=true`, `--no-watchdog` to disable).
  - Also starts OPS proxy adapter from `oak-chain-edge-worker`:
    - `OPS_MOCK_MODE=proxy OPS_UPSTREAM_BASE=http://127.0.0.1:8090 node src/ops-api-worker.mjs`
- `lifecycle/console.sh` (`oak-chain mock console`)
  - Interactive console: start/stop the cluster, start/stop/kill/restart single members, live member, quorum and service status.
  - Every action runs a lifecycle script; destructive actions and quorum-breaking member stops ask first.
- `lifecycle/member.sh start|stop|kill|restart|status <member-id>`
  - Per-member lifecycle. Members boot independently inside a static Aeron membership, so stopping one never shrinks the cluster.
  - `start` clears only that member's Aeron media-driver dir; cluster/archive state is kept so the member catches up from its peers.
  - Reads cluster size, ports, Aeron dirs and `EXTRA_JAVA_OPTS` from `$PID_DIR/cluster-launch.env` (written by `start-cluster.sh`) and refuses to start a member if your environment's membership differs. A restarted member of a sharded cluster keeps its sharding flags; an `EXTRA_JAVA_OPTS` set in your environment wins, with a warning when it differs from the record.
  - Only signals a pid whose command line names that member's store directory, so a stale or reused pid is never killed.
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
- `lifecycle/start-fed-3x2.sh` / `stop-fed-3x2.sh` / `status-fed-3x2.sh`
  - Enterprise-federation topology: cluster A (enterprise `0xa1…a1`, HTTP 8290/8292/8294, Aeron 9800, OPS proxy 8797) and cluster B (enterprise `0xb2…b2`, HTTP 8390/8392/8394, Aeron 10200, OPS proxy 8798), federated through one static-file directory (`$FED_3X2_ROOT/directory.json`) instead of `oak.sharding.*` routes. Config: `config/fed-3x2-*.env`.
  - Root-bound: they act only on `$FED_3X2_ROOT/cluster-{a,b}` (default root `$HOME/oak-chain-federation/3x2`) and refuse any root equal to, under, above or symlinked into `$HOME/oak-chain` (`lifecycle/lib/fed-3x2.sh`). `--fresh` resets only those roots and moves the directory file aside.
  - `start-fed-3x2.sh` requires `OAK_CONSENSUS_JAR` (the jar built from `jackrabbit-oak` `feature/enterprise-federation`), refuses `--build`, refuses ports held by anything outside the federation roots, keeps watchdog and load observer off, and never auto-starts IPFS.
  - Proof: `tests/routing/federation-3x2-smoke.sh` (see `tests/README.md`).
- `debug/run-validator-node.sh`
  - Runs one validator node directly for focused debugging.
  - `OAK_CONSENSUS_JAR=/abs/path.jar` runs that exact jar instead of the workspace search (which is otherwise unchanged) and prints its sha256; `OAK_CONSENSUS_JAR_SHA256` refuses the jar if its content changed. `start-cluster.sh` hashes it once, passes the hash to every member and stores path and hash in the launch record, so `member.sh` restarts the same jar and refuses another one.
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
- `monitoring/mock-scale-staircase-monitor.sh`
  - Polls a running mock staircase log, prints progress snapshots, and captures an investigation bundle when the run stalls or fails.
  - Default targets:
    - run log: `/tmp/oak-mock-scale-staircase-overnight.log`
    - artifact root: `/tmp/oak-mock-scale-staircase-artifacts`
  - Investigation output:
    - `/tmp/oak-mock-scale-staircase-artifacts/monitoring/mock-scale-staircase-investigation-<timestamp>/`

## Config

- `config/mock.env`
- `config/ipfs.env`
- `config/3x2-common.env`
- `config/3x2-cluster-a.env`
- `config/3x2-cluster-b.env`
- `config/fed-3x2-common.env`, `config/fed-3x2-cluster-a.env`, `config/fed-3x2-cluster-b.env`

## Smoke Validation

- `tests/validator-api-smoke.sh`
- `tests/sharding-3x2-smoke.sh`
- `tests/routing/federation-3x2-smoke.sh`
- `tests/mock-scale-staircase-monitor.sh`

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
- `IPFS_GATEWAY_BASE` (default: `http://127.0.0.1:5080/ipfs/`; written into committed content, so every member of a cluster must agree; recorded in the launch record)
- `IPFS_LOCAL_GATEWAY_BASE` (default: `http://127.0.0.1:5080/ipfs/`; port 5080 keeps the gateway off every validator port, see `TROUBLESHOOTING.md`)
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
- `OAK_CONSENSUS_JAR` (absolute path of the consensus jar every member runs; default: workspace search; recorded with its sha256 in the launch record)
- `FED_3X2_ROOT` (federation topology root, default `$HOME/oak-chain-federation/3x2`; never at or under `$HOME/oak-chain`)
- `EXTRA_JAVA_OPTS` (used by the multi-cluster configs to turn on sharding JVM flags; persisted in the launch record)
- `MONITOR_INTERVAL_SECONDS` (default: `30` for `mock-scale-staircase-monitor.sh`)
- `MONITOR_TIMEOUT_SECONDS` (default: `0` for `mock-scale-staircase-monitor.sh`, disabled)
- `STALL_SECONDS` (default: `900` for `mock-scale-staircase-monitor.sh`)
- `CONFIRMATION_ATTEMPTS` (default: `3` for `mock-scale-staircase-monitor.sh`)
- `CONFIRMATION_SLEEP_SECONDS` (default: `5` for `mock-scale-staircase-monitor.sh`)
