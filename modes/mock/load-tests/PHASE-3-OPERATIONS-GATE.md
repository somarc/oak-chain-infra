# Phase 3 Operations Gate (Concrete Runbook)

This is the execution checklist for deciding if the cluster is operationally ready after tuning changes.

## Goal

Pass a repeatable gate for:
- sustained ingest
- bounded overload behavior
- predictable drain-down after load stops
- acceptable log volume and error profile

## Gate Profile (Target)

- Test profile: `05-ultra-30min.sh`
- Target writes: `100000` in `1800s` (30 minutes)
- Cluster: 3 validators (`8090,8092,8094`) + OPS proxy (`8787`)

## 1. Preflight (Required)

Run from `oak-chain-infra/modes/mock`:

```bash
./validators/lifecycle/status-cluster.sh
```

Must show:
- validators `UP`
- `ipfs:UP`
- `ops-proxy:UP`
- `validator-watchdog:UP`

## 2. Start Evidence Capture (Before Load)

Terminal A (limit signature CSV):

```bash
./load-tests/capture-limit-signature.sh
```

Terminal B (jstack during load, all validators):

```bash
BASE="$HOME/oak-chain/logs/jstack/cluster-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BASE"
for p in 8090 8092 8094; do
  OUT="$BASE/port-$p"; mkdir -p "$OUT"
  nohup ./validators/monitoring/jstack-validator-series.sh \
    --port "$p" --duration 300 --delay 10 --out "$OUT" \
    > "$BASE/port-$p.run.log" 2>&1 &
done
echo "jstack base: $BASE"
```

Terminal C (live classification):

```bash
./load-tests/watch-load-evaluation.sh
```

## 3. Run the Benchmark Load

Terminal D:

```bash
cd load-tests
./05-ultra-30min.sh
```

## 4. Post-Run Drain Observation (Required)

After load ends, wait for drain and sample every 30s for at least 20 minutes:

```bash
for i in $(seq 1 40); do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  O=$(curl -s http://127.0.0.1:8787/ops/v1/overview)
  echo "$TS pending=$(echo "$O" | jq -r '.data.queue.pending') verified=$(echo "$O" | jq -r '.data.queue.verifier.successCount') finalized=$(echo "$O" | jq -r '.data.queue.processed // 0') lag=$(echo "$O" | jq -r '.data.replication.maxLagMs')"
  sleep 30
done | tee "$HOME/oak-chain/logs/drain-window-$(date +%Y%m%d-%H%M%S).log"
```

## 5. Automated Gate Scoring

Run benchmark gate with explicit thresholds:

```bash
cd load-tests
MAX_GAP_RATIO=0.45 \
MAX_429_RATE=0.12 \
MAX_VERIFIER_WAIT_AVG_MS=12000 \
MAX_VERIFIER_WAIT_MAX_MS=900000 \
./run-benchmark.sh \
  --load-script ./05-ultra-30min.sh \
  --target-writes 100000 \
  --target-duration 1800
```

Then run checklist scorer:

```bash
./adr068-checklist.sh
```

## 6. Log-Volume and Error Audit

Large-log risk and dominant spam sources:

```bash
LOG="$HOME/oak-chain/logs/validator-0.log"
wc -l "$LOG"
rg -n " WARN | ERROR " "$LOG" | wc -l
rg -n "Rate limit exceeded|Backpressure timeout|re-queuing batch|Exception|OutOfMemory|Too many open files" "$LOG" | head -n 200
```

Top logger classes:

```bash
rg " WARN | ERROR " "$HOME/oak-chain/logs/validator-0.log" \
| sed -E 's/.* (WARN|ERROR) ([^ ]+) -.*/\2/' \
| sort | uniq -c | sort -nr | head -n 20
```

## 7. Pass/Fail Criteria

A run is **PASS** only if all are true:

1. Throughput
- Benchmark gate `throughput_target=PASS`.

2. Overload boundedness
- `429` rate <= `12%` during test window.
- No process death/restart loops.

3. Finalization behavior
- Verified/finalized gap does not grow unbounded.
- Drain window shows monotonic backlog reduction.

4. Consensus durability/replication
- `durability.pendingAcks` returns to `0`.
- `durability.ackTimeouts` stays `0`.
- `replication.maxLagMs` returns near baseline.

5. Error budget
- No `OutOfMemoryError`.
- No `Too many open files`.
- Backpressure timeout events are finite and not continuously increasing after load stop.

6. Log-volume hygiene
- Dominant WARN spam is summarized (not per-request flood).
- Projected daily log volume is operationally acceptable for retention.

## 8. If Fail: Required Follow-up Matrix

Run next:

1. Persistence matrix:

```bash
./load-tests/08-proposal-persistence-sweep.sh
```

2. Multi-node ingress:

```bash
./load-tests/06-ultra-ultra-multi-node.sh
```

3. Rejoin/drain resilience:

```bash
./load-tests/07-rejoin-drain-draft.sh
```

Capture one short write-up per failed gate:
- observed symptom
- likely bottleneck path
- next knob/code change
- expected measurable effect
