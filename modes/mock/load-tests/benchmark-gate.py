#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import glob
import json
import re
import sys
from collections import defaultdict


LINE_DONE = re.compile(r"Client-(\d+)\s+done:\s+writes=(\d+),\s+ok=(\d+),\s+fail=(\d+)")
LINE_HTTP = re.compile(r"HTTP\s+(\d{3})")
LINE_HTTP_SUMMARY = re.compile(r"HTTP_SUMMARY\s+code=([A-Za-z0-9]+)\s+count=(\d+)")


def to_int(value):
    try:
        return int(value)
    except Exception:
        return None


def slope_per_second(points):
    if len(points) < 2:
        return None
    first_t, first_v = points[0]
    last_t, last_v = points[-1]
    dt_seconds = (last_t - first_t).total_seconds()
    if dt_seconds <= 0:
        return None
    return (last_v - first_v) / dt_seconds


def parse_test_log(path):
    started_at = None
    done_rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if started_at is None:
                m_ts = re.match(r"\[([0-9:\-\s]{19})\]", line)
                if m_ts:
                    try:
                        started_at = dt.datetime.strptime(m_ts.group(1), "%Y-%m-%d %H:%M:%S")
                    except Exception:
                        pass
            m_done = LINE_DONE.search(line)
            if m_done:
                done_rows.append(
                    {
                        "client": int(m_done.group(1)),
                        "writes": int(m_done.group(2)),
                        "ok": int(m_done.group(3)),
                        "fail": int(m_done.group(4)),
                    }
                )

    return {
        "started_at": started_at,
        "done_rows": done_rows,
        "clients_done": len(done_rows),
        "writes_total": sum(r["writes"] for r in done_rows),
        "ok_total": sum(r["ok"] for r in done_rows),
        "fail_total": sum(r["fail"] for r in done_rows),
    }


def parse_test_logs(paths):
    summaries = [parse_test_log(path) for path in paths]
    started_candidates = [s["started_at"] for s in summaries if s["started_at"] is not None]
    done_rows = []
    for summary in summaries:
        done_rows.extend(summary["done_rows"])
    return {
        "started_at": min(started_candidates) if started_candidates else None,
        "done_rows": done_rows,
        "clients_done": sum(s["clients_done"] for s in summaries),
        "writes_total": sum(s["writes_total"] for s in summaries),
        "ok_total": sum(s["ok_total"] for s in summaries),
        "fail_total": sum(s["fail_total"] for s in summaries),
    }


def parse_client_logs(paths):
    code_counts = defaultdict(int)
    files = sorted(set(paths))
    summary_seen = False
    for path in files:
        file_summary = {}
        file_codes = defaultdict(int)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                ms = LINE_HTTP_SUMMARY.search(line)
                if ms:
                    file_summary[ms.group(1)] = int(ms.group(2))
                    continue
                m = LINE_HTTP.search(line)
                if m:
                    file_codes[m.group(1)] += 1
        if file_summary:
            summary_seen = True
            for code, count in file_summary.items():
                code_counts[code] += count
        else:
            for code, count in file_codes.items():
                code_counts[code] += count
    if summary_seen:
        # Preserve compatibility for downstream 429 checks that expect 3-digit status keys.
        if "429" not in code_counts and "4xx" in code_counts:
            code_counts["429"] = 0
    return dict(code_counts), files


def select_node(rows_by_node):
    # Choose node with highest observed totalProposals (best signal),
    # tie-break by number of samples.
    best = None
    best_score = (-1, -1)
    for node, rows in rows_by_node.items():
        max_total_proposals = -1
        for row in rows:
            v = to_int(row.get("totalProposals"))
            if v is not None and v > max_total_proposals:
                max_total_proposals = v
        score = (max_total_proposals, len(rows))
        if score > best_score:
            best_score = score
            best = node
    return best


def aggregate_rows_by_timestamp(rows_by_node):
    sum_fields = {
        "totalProposals",
        "totalVerifiedCount",
        "totalFinalizedCount",
        "processedCount",
        "pendingCount",
        "backpressurePendingCount",
        "verifierErrorCount",
    }
    max_fields = {
        "verifierQueueWaitAvgMs",
        "verifierQueueWaitMaxMs",
    }
    aggregate = {}
    for rows in rows_by_node.values():
        for row in rows:
            ts = row.get("timestamp", "")
            bucket = aggregate.setdefault(ts, {"timestamp": ts, "node": "ALL"})
            for field in sum_fields:
                value = to_int(row.get(field))
                if value is not None:
                    bucket[field] = bucket.get(field, 0) + value
            for field in max_fields:
                value = to_int(row.get(field))
                if value is not None and value >= 0:
                    bucket[field] = max(bucket.get(field, value), value)
    return [aggregate[ts] for ts in sorted(aggregate.keys())]


def analyze_queue_csv(path, tail_window_seconds=60, node_override=""):
    rows_by_node = defaultdict(list)
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows_by_node[row.get("node", "")].append(row)

    if node_override == "ALL":
        rows = aggregate_rows_by_timestamp(rows_by_node)
        node = "ALL"
    else:
        node = node_override if node_override else select_node(rows_by_node)
        if node_override and node_override not in rows_by_node:
            raise RuntimeError(f"requested queue node '{node_override}' has no samples in CSV")
        rows = rows_by_node.get(node, [])

    if node != "ALL" and node_override and node_override not in rows_by_node:
        raise RuntimeError(f"requested queue node '{node_override}' has no samples in CSV")
    if not node or len(rows) < 2:
        raise RuntimeError("insufficient queue samples for benchmark analysis")
    first = rows[0]
    last = rows[-1]
    first_ts = dt.datetime.strptime(first["timestamp"], "%Y-%m-%d %H:%M:%S")
    last_ts = dt.datetime.strptime(last["timestamp"], "%Y-%m-%d %H:%M:%S")
    duration_seconds = max(1.0, (last_ts - first_ts).total_seconds())

    def delta(field):
        a = to_int(first.get(field))
        b = to_int(last.get(field))
        if a is None or b is None:
            return None
        return b - a

    total_proposals_delta = delta("totalProposals")
    total_verified_delta = delta("totalVerifiedCount")
    total_finalized_delta = delta("totalFinalizedCount")
    processed_delta = delta("processedCount")

    finalized_delta = total_finalized_delta if total_finalized_delta is not None else processed_delta
    finalized_counter = "totalFinalizedCount" if total_finalized_delta is not None else "processedCount"
    verified_counter = "totalVerifiedCount" if total_verified_delta is not None else "verifiedCount"

    drift_points = []
    pending_points = []
    backpressure_points = []
    verifier_wait_avg_points = []
    verifier_wait_max_points = []
    verifier_error_points = []

    for r in rows:
        ts = dt.datetime.strptime(r["timestamp"], "%Y-%m-%d %H:%M:%S")
        verified = to_int(r.get("totalVerifiedCount"))
        finalized = to_int(r.get("totalFinalizedCount"))
        if verified is not None and finalized is not None:
            drift_points.append((ts, verified - finalized))
        else:
            processed = to_int(r.get("processedCount"))
            if verified is not None and processed is not None:
                drift_points.append((ts, verified - processed))
        pending = to_int(r.get("pendingCount"))
        if pending is not None:
            pending_points.append((ts, pending))
        backpressure = to_int(r.get("backpressurePendingCount"))
        if backpressure is not None and backpressure >= 0:
            backpressure_points.append((ts, backpressure))
        wait_avg = to_int(r.get("verifierQueueWaitAvgMs"))
        if wait_avg is not None and wait_avg >= 0:
            verifier_wait_avg_points.append((ts, wait_avg))
        wait_max = to_int(r.get("verifierQueueWaitMaxMs"))
        if wait_max is not None and wait_max >= 0:
            verifier_wait_max_points.append((ts, wait_max))
        verifier_err = to_int(r.get("verifierErrorCount"))
        if verifier_err is not None and verifier_err >= 0:
            verifier_error_points.append((ts, verifier_err))

    tail_start = last_ts - dt.timedelta(seconds=max(1, tail_window_seconds))
    pending_tail = [p for p in pending_points if p[0] >= tail_start]
    backpressure_tail = [p for p in backpressure_points if p[0] >= tail_start]
    drift_tail = [p for p in drift_points if p[0] >= tail_start]

    drift_values = [v for _, v in drift_points]
    pending_values = [v for _, v in pending_points]
    backpressure_values = [v for _, v in backpressure_points]
    verifier_wait_avg_values = [v for _, v in verifier_wait_avg_points]
    verifier_wait_max_values = [v for _, v in verifier_wait_max_points]
    verifier_error_values = [v for _, v in verifier_error_points]

    return {
        "node": node,
        "samples": len(rows),
        "first_ts": first_ts,
        "last_ts": last_ts,
        "duration_seconds": duration_seconds,
        "total_proposals_delta": total_proposals_delta,
        "total_verified_delta": total_verified_delta,
        "total_finalized_delta": total_finalized_delta,
        "finalized_delta": finalized_delta,
        "processed_delta": processed_delta,
        "ingest_rps": (total_proposals_delta / duration_seconds) if total_proposals_delta is not None else None,
        "verify_rps": (total_verified_delta / duration_seconds) if total_verified_delta is not None else None,
        "finalized_rps": (finalized_delta / duration_seconds) if finalized_delta is not None else None,
        "verified_counter": verified_counter,
        "finalized_counter": finalized_counter,
        "drift_end": drift_values[-1] if drift_values else None,
        "drift_max": max(drift_values) if drift_values else None,
        "drift_tail_slope_per_s": slope_per_second(drift_tail),
        "pending_end": pending_values[-1] if pending_values else None,
        "pending_max": max(pending_values) if pending_values else None,
        "pending_tail_slope_per_s": slope_per_second(pending_tail),
        "backpressure_end": backpressure_values[-1] if backpressure_values else None,
        "backpressure_max": max(backpressure_values) if backpressure_values else None,
        "backpressure_tail_slope_per_s": slope_per_second(backpressure_tail),
        "verifier_queue_wait_avg_ms_end": verifier_wait_avg_values[-1] if verifier_wait_avg_values else None,
        "verifier_queue_wait_avg_ms_max": max(verifier_wait_avg_values) if verifier_wait_avg_values else None,
        "verifier_queue_wait_max_ms_end": verifier_wait_max_values[-1] if verifier_wait_max_values else None,
        "verifier_queue_wait_max_ms_max": max(verifier_wait_max_values) if verifier_wait_max_values else None,
        "verifier_error_count_end": verifier_error_values[-1] if verifier_error_values else None,
    }


def main():
    parser = argparse.ArgumentParser(description="Evaluate load-test benchmark gate.")
    parser.add_argument("--queue-csv", required=True, help="Path to queue sampler CSV")
    parser.add_argument("--test-log", action="append", default=[], help="Path to a main load-test log (non-client); repeat for multi-node runs")
    parser.add_argument("--test-log-glob", default="", help="Optional glob that expands to main load-test logs")
    parser.add_argument("--client-log", action="append", default=[], help="Path to a client log; repeat for multi-node runs")
    parser.add_argument("--client-logs-glob", default="", help="Optional glob for client logs")
    parser.add_argument("--target-writes", type=int, default=100000, help="Target finalized writes for reference window")
    parser.add_argument("--target-duration-seconds", type=int, default=1800, help="Reference duration in seconds")
    parser.add_argument("--tail-window-seconds", type=int, default=60, help="Tail window used for slope-based checks")
    parser.add_argument("--max-gap-ratio", type=float, default=0.25, help="Allowed verified-finalized drift ratio over required finalized count")
    parser.add_argument("--max-gap-absolute", type=int, default=5000, help="Minimum absolute allowed verified-finalized drift")
    parser.add_argument("--max-pending-slope-per-s", type=float, default=2.0, help="Max allowed pending queue slope in tail window")
    parser.add_argument("--max-backpressure-slope-per-s", type=float, default=1.0, help="Max allowed backpressure slope in tail window")
    parser.add_argument("--max-verifier-wait-avg-ms", type=int, default=5000, help="Max allowed verifier queue wait avg (ms)")
    parser.add_argument("--max-verifier-wait-max-ms", type=int, default=60000, help="Max allowed verifier queue wait max (ms)")
    parser.add_argument("--max-429-rate", type=float, default=0.05, help="Allowed 429 fraction over total requests")
    parser.add_argument("--recovery-max-pending-end", type=int, default=2000, help="Max pending queue at end-of-window for recovery gate")
    parser.add_argument("--strict-unknown", action="store_true", help="Fail when required metrics are unavailable")
    parser.add_argument("--queue-node", default="", help="Force queue analysis to a specific node/port")
    parser.add_argument("--json-out", default="", help="Optional JSON output path")
    args = parser.parse_args()

    test_logs = list(args.test_log)
    if args.test_log_glob:
        test_logs.extend(sorted(glob.glob(args.test_log_glob)))
    test_logs = sorted(set(test_logs))
    if not test_logs:
        parser.error("at least one --test-log or --test-log-glob match is required")

    client_logs = list(args.client_log)
    if args.client_logs_glob:
        client_logs.extend(sorted(glob.glob(args.client_logs_glob)))
    client_logs = sorted(set(client_logs))
    if not client_logs:
        parser.error("at least one --client-log or --client-logs-glob match is required")

    queue = analyze_queue_csv(
        args.queue_csv,
        tail_window_seconds=args.tail_window_seconds,
        node_override=args.queue_node,
    )
    test = parse_test_logs(test_logs)
    code_counts, client_files = parse_client_logs(client_logs)

    target_rps = args.target_writes / float(args.target_duration_seconds)
    required_finalized = int(round(target_rps * queue["duration_seconds"]))
    finalized_delta = queue.get("finalized_delta") or 0
    finalized_rps = queue["finalized_rps"] or 0.0

    pass_rps = finalized_rps >= target_rps
    pass_volume = finalized_delta >= required_finalized

    throughput_gate = pass_rps and pass_volume

    gap_cap = max(args.max_gap_absolute, int(round(required_finalized * args.max_gap_ratio)))
    drift_end = queue.get("drift_end")
    gap_gate = drift_end is not None and drift_end <= gap_cap
    gap_reason = f"drift_end={drift_end} cap={gap_cap}"

    pending_slope = queue.get("pending_tail_slope_per_s")
    backpressure_slope = queue.get("backpressure_tail_slope_per_s")
    queue_gate = (
        pending_slope is not None
        and pending_slope <= args.max_pending_slope_per_s
        and (
            backpressure_slope is None
            or backpressure_slope <= args.max_backpressure_slope_per_s
        )
    )
    queue_reason = (
        f"pending_slope={pending_slope} max={args.max_pending_slope_per_s}, "
        f"backpressure_slope={backpressure_slope} max={args.max_backpressure_slope_per_s}"
    )

    verifier_wait_avg_ms = queue.get("verifier_queue_wait_avg_ms_end")
    verifier_wait_max_ms = queue.get("verifier_queue_wait_max_ms_end")
    latency_gate = (
        verifier_wait_avg_ms is not None
        and verifier_wait_max_ms is not None
        and verifier_wait_avg_ms <= args.max_verifier_wait_avg_ms
        and verifier_wait_max_ms <= args.max_verifier_wait_max_ms
    )
    latency_reason = (
        f"verifier_wait_avg_ms={verifier_wait_avg_ms} max={args.max_verifier_wait_avg_ms}, "
        f"verifier_wait_max_ms={verifier_wait_max_ms} max={args.max_verifier_wait_max_ms}"
    )

    total_requests = test["ok_total"] + test["fail_total"]
    http_429 = code_counts.get("429", 0)
    http_429_rate = (http_429 / float(total_requests)) if total_requests > 0 else None
    error_budget_gate = http_429_rate is not None and http_429_rate <= args.max_429_rate
    error_budget_reason = f"429_rate={http_429_rate} max={args.max_429_rate} (429={http_429} total={total_requests})"

    pending_end = queue.get("pending_end")
    drift_slope = queue.get("drift_tail_slope_per_s")
    recovery_gate = (
        pending_end is not None
        and pending_end <= args.recovery_max_pending_end
        and drift_slope is not None
        and drift_slope <= 0
    )
    recovery_reason = (
        f"pending_end={pending_end} max={args.recovery_max_pending_end}, "
        f"drift_tail_slope={drift_slope} (must be <= 0)"
    )

    checks = {
        "throughput_target": {
            "ok": throughput_gate,
            "reason": (
                f"finalized_rps={finalized_rps:.4f} target_rps={target_rps:.4f}; "
                f"finalized_delta={finalized_delta} required={required_finalized}"
            ),
        },
        "gap_control": {"ok": gap_gate, "reason": gap_reason},
        "queue_control": {"ok": queue_gate, "reason": queue_reason},
        "latency_control": {"ok": latency_gate, "reason": latency_reason},
        "error_budget": {"ok": error_budget_gate, "reason": error_budget_reason},
        "recovery_control": {"ok": recovery_gate, "reason": recovery_reason},
    }

    if args.strict_unknown:
        # In strict mode, any gate with missing metric should fail hard.
        for gate in checks.values():
            if "None" in gate["reason"]:
                gate["ok"] = False

    passed = all(g["ok"] for g in checks.values())

    result = {
        "passed": passed,
        "gate": {
            "target_writes": args.target_writes,
            "target_duration_seconds": args.target_duration_seconds,
            "target_rps": target_rps,
            "required_finalized_for_observed_window": required_finalized,
            "tail_window_seconds": args.tail_window_seconds,
            "max_gap_ratio": args.max_gap_ratio,
            "max_gap_absolute": args.max_gap_absolute,
            "max_pending_slope_per_s": args.max_pending_slope_per_s,
            "max_backpressure_slope_per_s": args.max_backpressure_slope_per_s,
            "max_verifier_wait_avg_ms": args.max_verifier_wait_avg_ms,
            "max_verifier_wait_max_ms": args.max_verifier_wait_max_ms,
            "max_429_rate": args.max_429_rate,
            "recovery_max_pending_end": args.recovery_max_pending_end,
        },
        "queue_metrics": queue,
        "load_metrics": test,
        "test_log_files": len(test_logs),
        "client_http_errors": code_counts,
        "client_log_files": len(client_files),
        "checks": checks,
    }

    print("Benchmark Gate")
    print(f"- Result: {'PASS' if passed else 'FAIL'}")
    print(f"- Node analyzed: {queue['node']} ({queue['samples']} samples)")
    print(
        f"- Finalized delta: {finalized_delta} over {queue['duration_seconds']:.1f}s "
        f"({finalized_rps:.2f}/s), target {target_rps:.2f}/s"
    )
    print(f"- Verify/Finalize drift: end={queue['drift_end']} max={queue['drift_max']}")
    print(
        f"- Ingest/Verify rates: ingest={queue['ingest_rps']:.2f}/s "
        f"verify={queue['verify_rps']:.2f}/s"
        if queue["ingest_rps"] is not None and queue["verify_rps"] is not None
        else "- Ingest/Verify rates: unavailable"
    )
    print(
        f"- Load outcomes (clients done={test['clients_done']}): "
        f"ok={test['ok_total']} fail={test['fail_total']} writes={test['writes_total']}"
    )
    print(f"- Client HTTP errors: 429={http_429} total={sum(code_counts.values())} rate={http_429_rate}")
    print("- ADR-068 Gate Checklist:")
    for gate_name, gate in checks.items():
        status = "PASS" if gate["ok"] else "FAIL"
        print(f"  - {gate_name}: {status} ({gate['reason']})")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, sort_keys=True, default=str)
        print(f"- JSON report: {args.json_out}")

    sys.exit(0 if passed else 2)


if __name__ == "__main__":
    main()
