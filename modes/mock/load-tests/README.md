# Load Test Scripts (Authoritative Suite)

Progressive load tests for validating Oak Chain performance and stability.

## Ladder (Progressive Intensity)

| Script | Duration | Clients | Writes/Client | Binary Mix | Purpose |
|--------|----------|---------|---------------|------------|---------|
| `00-smoke-one-write.sh` | ~1 min | 1 | 1 | none | Sanity check (API + consensus path) |
| `01-light-5min.sh` | 5 min | 5 | 100–400 | 5% | Quick throughput check |
| `02-medium-15min.sh` | 15 min | 10 | 300–1200 | 10% | Sustained mixed load |
| `03-heavy-30min.sh` | 30 min | 15 | 500–5000 | 20% | Stress with mixed binary modes |
| `04-soak-2h.sh` | 2 hours | 20 | 1000–10000 | 15% | Long-running stability |

Binary mix defaults:
- Client-side IPFS CIDs are the default.
- Validator-hosted binaries (multipart) require `paymentTier=PRIORITY` and are a smaller subset of binary traffic.

## How to Run

```bash
# Ensure validators are running
./local-dev.sh start validators --fresh

# Smoke test
./load-tests/00-smoke-one-write.sh

# Heavy test
./load-tests/03-heavy-30min.sh
```

## Config Knobs (Env Vars)

```bash
export VALIDATOR_URL=http://localhost:8090
export TEST_DURATION_SECONDS=1800
export NUM_CLIENTS=15
export MIN_WRITES_PER_CLIENT=500
export MAX_WRITES_PER_CLIENT=5000
export BINARY_PERCENT=20
export VALIDATOR_BINARY_PERCENT=30
export SLEEP_MIN_MS=25
export SLEEP_MAX_MS=200
```

## Logs

Logs go to: `~/oak-chain/logs` by default. Override with `LOG_DIR`.

## Monitoring

- `monitor-metrics.sh` — polls consensus/lag/pending and writes CSV log
- `monitor-validator-logs.sh` — tails validator logs with filtering and timestamps
- `queue-sampler.py` — samples mempool/queue stats from all validators into CSV
- `analyze-queue-samples.py` — computes ingest/verify/processed rates from sampler CSV
- `run-bottleneck-study.sh` — turnkey runner for all monitors with a fixed duration

## Legacy Scripts

Archived under `load-tests/archive/legacy-2026-02-03/`.
