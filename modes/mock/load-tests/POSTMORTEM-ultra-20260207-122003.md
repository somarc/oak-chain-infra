# Postmortem: ultra-30min (2026-02-07 12:20:03 local)

## Scope
- Load profile: `05-ultra-30min.sh`
- Start: `2026-02-07 12:20:03` local (`2026-02-07T17:20:03Z`)
- End: `2026-02-07 12:50:06` local (`2026-02-07T17:50:06Z`)
- Artifacts:
  - `/Users/mhess/oak-chain/logs/ultra-30min-20260207-122003.log`
  - `/Users/mhess/oak-chain/logs/limit-signature-20260207-122000.csv`
  - `/Users/mhess/oak-chain/logs/validator-0.log`
  - `/Users/mhess/oak-chain/logs/validator-1.log`
  - `/Users/mhess/oak-chain/logs/validator-2.log`

## Executive Summary
- The prior backpressure deadlock signature did **not** recur in this run.
- System remained available but operated in sustained overload mode with heavy `429` throttling.
- Primary bottleneck shifted to finalization throughput relative to verification/ingress throughput.
- Queue backlog grew significantly during the 30-minute window and remained elevated at run end.

## Key Metrics

### Client outcomes (from `ultra-30min-20260207-122003.log`)
- Sum of random per-client targets: `327,010` writes
- Completed writes attempted: `189,854`
- Successes: `161,426`
- Failures: `28,428`
- `429` count: `28,428` (all failures were `429`)
- `429` failure rate on attempted writes: `14.97%`
- `5xx`: `0`
- transport (`http000`): `0`

### Queue/finality progression (from `limit-signature-20260207-122000.csv`)
- Sample window: `2026-02-07T17:20:00Z` -> `2026-02-07T17:49:57Z` (342 samples, 5s cadence)
- Queue pending:
  - start: `0`
  - end: `42,336`
  - max observed: `42,704`
- Total verified:
  - start: `0`
  - end: `160,756`
  - avg delta/sample: `470.05` (~`94.0/s`)
- Total finalized:
  - start: `0`
  - end: `117,253`
  - avg delta/sample: `342.85` (~`68.6/s`)
- Verified-finalized gap at end: `43,503` (`160,756 - 117,253`)
- Max backpressure pending: `5`
- Max verifier queue wait: `538 ms`
- Max durability pending acks: `384`
- Max replication lag: `0 ms`

## What We Learned

## 1) Deadlock class was mitigated
- Previous incident signature: `backpressurePending` stuck high, `sent/acked` not moving, queue frozen.
- This run signature: no prolonged backpressure debt lock (`max_backpressure_pending=5`), no lockup behavior in run-level counters.
- Conclusion: the sent/acked accounting fix removed the specific stall mode we observed earlier.

## 2) Overload behavior is now bounded but expensive
- `429` is the dominant overload mechanism and stayed controlled (no `5xx`, no transport failures).
- However, `~15%` reject rate during this profile is still high for a 100k/30m target posture.

## 3) Finalization throughput is the limiting stage
- Verified rate (~94/s) exceeded finalized rate (~69/s) throughout the run.
- Net queue growth ~25/s drove pending queue to ~42k by run end.
- Replication and verifier were not primary bottlenecks in this run (`lag=0`, low verifier wait).
- Durability shows intermittent pressure (pending ack spikes), but no timeouts.

## 4) Logging is improved but still noisy at INFO
- `validator-0.log` line count: `596,369`
- WARN/ERROR remained low (`WARN=140`, `ERROR=7`) and mostly meaningful.
- High INFO chatter remains in sender/epoch debug-like flows and can inflate log volume under sustained load.

## Bottleneck Diagnosis (Current)

## Primary
- Finalization/drain capacity vs ingest pressure:
  - `delta_verified > delta_finalized` consistently
  - queue grows despite healthy verifier and replication.

## Secondary
- Durability ack pressure bursts during sustained throughput:
  - `durability.pendingAcks` spikes indicate periodic persistence/ack coordination overhead.

## Not Primary in this run
- Backpressure lock/deadlock
- Replication lag
- Verifier latency/errors

## Recommendations

## Immediate (next run)
1. Collect explicit post-run drain window (20-30 min) before shutdown.
2. Compare finalization slope under two tuning variants:
   - `oak.proposal.finalization.chunk.size` (`3` vs `6`)
   - `oak.proposal.batch.max` (`10` vs `20`)
3. Keep current deadlock fix baseline unchanged while tuning throughput.

## Near-term (code + ops)
1. Add explicit metrics for finalization stage throughput and chunk latency in OPS API.
2. Surface derived `verified-finalized gap ratio` and `drain slope` directly in `/ops/v1/signals`.
3. Add guardrails/alerts on sustained positive queue slope after ingress drops.
4. Reduce high-frequency INFO lines in epoch/sender loops for production mode.

## Test matrix to run next
1. Baseline: current knobs, same ultra profile.
2. Chunk/batch tuning sweep:
   - `chunk=6, batch=10`
   - `chunk=3, batch=20`
   - `chunk=6, batch=20`
3. Persistence sweep (already drafted):
   - `persistence_enabled on/off`
   - flush interval/batch variants.

## Decision
- Mark previous backpressure deadlock as **resolved for this profile**.
- Mark overall 100k/30m objective as **not yet met** due finalization lag and `429` rate.
- Continue on throughput optimization track (finalization-first), not deadlock recovery.
