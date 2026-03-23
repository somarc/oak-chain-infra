#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.request


COUNTER_FIELDS = [
    "totalProposals",
    "totalVerifiedCount",
    "totalFinalizedCount",
    "processedCount",
]


def fetch_json(url: str, timeout: float = 3.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            return json.loads(body), None
    except Exception as exc:
        return {}, str(exc)


def to_int(value):
    try:
        return int(value)
    except Exception:
        return None


def emit(lines, json_out=""):
    for k, v in lines.items():
        print(f"{k}={v}")
    if json_out:
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump(lines, f, indent=2, sort_keys=True)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Validate leader-sensitive metric sampling context before benchmark scoring."
        )
    )
    parser.add_argument("--host", default="http://127.0.0.1", help="Validator host base URL")
    parser.add_argument("--nodes", default="8090,8092,8094", help="Comma-separated node ports")
    parser.add_argument("--sample-node", default="", help="Port intended for leader-sensitive sampling")
    parser.add_argument(
        "--max-counter-delta",
        type=int,
        default=0,
        help="Allowed absolute delta between leader and sample counters",
    )
    parser.add_argument("--json-out", default="", help="Optional JSON output path")
    args = parser.parse_args()

    nodes = [p.strip() for p in args.nodes.split(",") if p.strip()]
    sample_node = args.sample_node.strip() if args.sample_node.strip() else (nodes[0] if nodes else "")

    status_by_node = {}
    queue_by_node = {}
    role_by_node = {}
    unreachable = []

    for node in nodes:
        status, status_err = fetch_json(f"{args.host}:{node}/v1/consensus/status")
        queue, queue_err = fetch_json(f"{args.host}:{node}/v1/proposals/queue/stats")
        role = str(status.get("currentRole", "")).upper()
        role_by_node[node] = role
        status_by_node[node] = status
        queue_by_node[node] = queue
        if status_err and queue_err:
            unreachable.append(node)

    leaders = [n for n in nodes if role_by_node.get(n) == "LEADER"]
    leader_node = leaders[0] if len(leaders) == 1 else ""

    reasons = []
    if not nodes:
        reasons.append("no nodes provided")
    if sample_node and sample_node not in nodes:
        reasons.append(f"sample node {sample_node} is not in nodes list")
    if len(leaders) == 0:
        reasons.append("no LEADER role detected from /v1/consensus/status")
    elif len(leaders) > 1:
        reasons.append(f"multiple leaders reported: {','.join(leaders)}")
    if unreachable:
        reasons.append(f"unreachable nodes (status+queue): {','.join(unreachable)}")

    sample_is_leader = bool(leader_node and sample_node == leader_node)
    deltas = {}
    max_delta = None

    if leader_node and sample_node in queue_by_node:
        leader_stats = queue_by_node.get(leader_node, {})
        sample_stats = queue_by_node.get(sample_node, {})
        for field in COUNTER_FIELDS:
            leader_val = to_int(leader_stats.get(field))
            sample_val = to_int(sample_stats.get(field))
            if leader_val is None or sample_val is None:
                continue
            deltas[field] = abs(leader_val - sample_val)
        if deltas:
            max_delta = max(deltas.values())

    counters_within_tolerance = max_delta is None or max_delta <= args.max_counter_delta
    if max_delta is not None and not counters_within_tolerance:
        reasons.append(
            f"leader/sample counter delta too high: max_delta={max_delta} "
            f"max_allowed={args.max_counter_delta}"
        )
    if leader_node and sample_node and not sample_is_leader:
        reasons.append(
            f"leader-sensitive metrics sampled from non-leader: "
            f"sample={sample_node} leader={leader_node}"
        )

    parity_ok = (
        bool(leader_node)
        and bool(sample_node)
        and sample_is_leader
        and counters_within_tolerance
        and not unreachable
    )

    lines = {
        "RESULT": "PASS" if parity_ok else "FAIL",
        "PARITY_OK": str(parity_ok).lower(),
        "HOST": args.host,
        "NODES": ",".join(nodes),
        "SAMPLE_NODE": sample_node,
        "LEADER_NODE": leader_node,
        "SAMPLE_IS_LEADER": str(sample_is_leader).lower(),
        "MAX_COUNTER_DELTA": "" if max_delta is None else str(max_delta),
        "MAX_ALLOWED_COUNTER_DELTA": str(args.max_counter_delta),
        "ROLES": ",".join(f"{n}:{role_by_node.get(n,'')}" for n in nodes),
        "REASON": "ok" if parity_ok else "; ".join(reasons) if reasons else "parity check failed",
        "COUNTER_DELTAS": ",".join(f"{k}:{v}" for k, v in sorted(deltas.items())),
    }
    emit(lines, args.json_out)

    sys.exit(0 if parity_ok else 2)


if __name__ == "__main__":
    main()
