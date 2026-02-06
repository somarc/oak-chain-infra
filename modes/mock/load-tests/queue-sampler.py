#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import json
import time
import urllib.request

def fetch_json(url: str, timeout: float = 3.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            data = resp.read().decode("utf-8", "replace")
            return json.loads(data)
    except Exception:
        return {}

def main():
    parser = argparse.ArgumentParser(description="Sample queue/mempool stats from validators.")
    parser.add_argument("--host", default="http://localhost", help="Base host (default: http://localhost)")
    parser.add_argument("--nodes", default="8090,8092,8094", help="Comma-separated ports")
    parser.add_argument("--interval", type=int, default=10, help="Seconds between samples")
    parser.add_argument("--duration", type=int, default=0, help="Total seconds to run (0 = forever)")
    parser.add_argument("--out", default="", help="CSV output path")
    args = parser.parse_args()

    ports = [p.strip() for p in args.nodes.split(",") if p.strip()]
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = args.out or f"{args.host.replace('://','_').replace(':','_')}_queue_samples_{ts}.csv"

    fieldnames = [
        "timestamp",
        "node",
        "role",
        "mempoolSize",
        "pendingCount",
        "verifiedCount",
        "batchQueueSize",
        "totalProposals",
        "totalVerifiedCount",
        "processedCount",
        "currentEpoch",
        "finalizedEpoch",
    ]

    start = time.time()
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        while True:
            now = time.time()
            if args.duration > 0 and (now - start) >= args.duration:
                break

            for port in ports:
                base = f"{args.host}:{port}"
                queue = fetch_json(f"{base}/v1/proposals/queue/stats")
                pending = fetch_json(f"{base}/v1/proposals/pending/count")
                consensus = fetch_json(f"{base}/v1/consensus/status")

                row = {
                    "timestamp": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    "node": port,
                    "role": consensus.get("currentRole", ""),
                    "mempoolSize": queue.get("mempoolSize", ""),
                    "pendingCount": pending.get("pendingCount", ""),
                    "verifiedCount": queue.get("verifiedCount", ""),
                    "batchQueueSize": queue.get("batchQueueSize", ""),
                    "totalProposals": queue.get("totalProposals", ""),
                    "totalVerifiedCount": queue.get("totalVerifiedCount", ""),
                    "processedCount": queue.get("processedCount", ""),
                    "currentEpoch": queue.get("currentEpoch", ""),
                    "finalizedEpoch": queue.get("finalizedEpoch", ""),
                }
                writer.writerow(row)
                f.flush()

            time.sleep(args.interval)

    print(out_path)

if __name__ == "__main__":
    main()
