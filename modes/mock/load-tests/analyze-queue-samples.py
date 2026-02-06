#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
from collections import defaultdict

def to_int(value):
    try:
        return int(value)
    except Exception:
        return None

def main():
    parser = argparse.ArgumentParser(description="Analyze queue sample CSVs and compute rates.")
    parser.add_argument("csv", help="Path to queue samples CSV")
    args = parser.parse_args()

    rows_by_node = defaultdict(list)
    with open(args.csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            node = row.get("node", "")
            rows_by_node[node].append(row)

    for node, rows in rows_by_node.items():
        if len(rows) < 2:
            continue
        first = rows[0]
        last = rows[-1]
        samples = len(rows)
        span_seconds = 0.0
        try:
            first_ts = dt.datetime.strptime(first.get("timestamp", ""), "%Y-%m-%d %H:%M:%S")
            last_ts = dt.datetime.strptime(last.get("timestamp", ""), "%Y-%m-%d %H:%M:%S")
            span_seconds = max(0.0, (last_ts - first_ts).total_seconds())
        except Exception:
            span_seconds = max(0.0, (samples - 1) * 1.0)
        mempool_first = to_int(first.get("mempoolSize"))
        mempool_last = to_int(last.get("mempoolSize"))
        total_verified_first = to_int(first.get("totalVerifiedCount"))
        total_verified_last = to_int(last.get("totalVerifiedCount"))
        total_proposals_first = to_int(first.get("totalProposals"))
        total_proposals_last = to_int(last.get("totalProposals"))
        processed_first = to_int(first.get("processedCount"))
        processed_last = to_int(last.get("processedCount"))

        def rate(delta):
            if span_seconds <= 0:
                return 0.0
            return delta / span_seconds

        deltas = {
            "mempool": (mempool_last - mempool_first) if mempool_first is not None and mempool_last is not None else None,
            "verified": (total_verified_last - total_verified_first) if total_verified_first is not None and total_verified_last is not None else None,
            "ingest": (total_proposals_last - total_proposals_first) if total_proposals_first is not None and total_proposals_last is not None else None,
            "processed": (processed_last - processed_first) if processed_first is not None and processed_last is not None else None,
        }

        print(f"\nNode {node}")
        print(f"  samples: {samples}")
        if deltas["mempool"] is not None:
            print(f"  mempool Δ: {deltas['mempool']} (rate: {rate(deltas['mempool']):.2f}/s)")
        if deltas["ingest"] is not None:
            print(f"  totalProposals Δ: {deltas['ingest']} (ingest rate: {rate(deltas['ingest']):.2f}/s)")
        if deltas["verified"] is not None:
            print(f"  totalVerified Δ: {deltas['verified']} (verify rate: {rate(deltas['verified']):.2f}/s)")
        if deltas["processed"] is not None:
            print(f"  processed Δ: {deltas['processed']} (process rate: {rate(deltas['processed']):.2f}/s)")

if __name__ == "__main__":
    main()
