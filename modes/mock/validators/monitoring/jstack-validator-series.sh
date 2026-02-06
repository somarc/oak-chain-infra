#!/bin/bash
set -euo pipefail

usage() {
  cat << 'EOF'
Capture a series of thread dumps + top output for a validator process.

Usage:
  ./jstack-validator-series.sh [--port 8090] [--pid PID] [--count N] [--delay S] [--duration S] [--out DIR]

Defaults:
  --port 8090
  --count 10
  --delay 1

Notes:
  - If --pid is not provided, the PID is resolved from the listening port.
  - Use --duration to run for a fixed time; count is derived from duration/delay.
  - Output files are written under ~/oak-chain/logs/jstack/ by default.

Examples:
  ./jstack-validator-series.sh --port 8090 --count 60 --delay 10
  ./jstack-validator-series.sh --duration 1800 --delay 10   # 30 minutes
EOF
}

PORT=8090
PID=""
COUNT=10
DELAY=1
DURATION=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    --pid)
      PID="$2"; shift 2 ;;
    --count)
      COUNT="$2"; shift 2 ;;
    --delay)
      DELAY="$2"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --out)
      OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 1 ;;
  esac
done

if [[ -n "$DURATION" ]]; then
  if [[ "$DELAY" -le 0 ]]; then
    echo "Delay must be > 0 when using --duration" >&2
    exit 1
  fi
  COUNT=$((DURATION / DELAY))
  if [[ "$COUNT" -le 0 ]]; then
    echo "Duration too short for delay" >&2
    exit 1
  fi
fi

if [[ -z "$PID" ]]; then
  if command -v lsof >/dev/null 2>&1; then
    PID=$(lsof -ti "tcp:${PORT}" -sTCP:LISTEN | head -n 1 || true)
  fi
fi

if [[ -z "$PID" ]]; then
  echo "Unable to resolve PID for port ${PORT}. Use --pid." >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  OUT_DIR="$HOME/oak-chain/logs/jstack/validator-${PORT}.${PID}.${TS}"
fi

mkdir -p "$OUT_DIR"

if command -v jstack >/dev/null 2>&1; then
  JSTACK_CMD=(jstack -l "$PID")
elif command -v jcmd >/dev/null 2>&1; then
  JSTACK_CMD=(jcmd "$PID" Thread.print -l)
else
  echo "jstack/jcmd not found on PATH. Ensure JDK bin is on PATH." >&2
  exit 1
fi

OS="$(uname)"
if [[ "$OS" == "Darwin" ]]; then
  TOP_CMD=(top -pid "$PID" -l 1)
else
  TOP_CMD=(top -H -b -n1 -p "$PID")
fi

{
  echo "port=${PORT}"
  echo "pid=${PID}"
  echo "cmdline=$(ps -p "$PID" -o args=)"
  echo "host=$(hostname)"
  if date -u +%Y-%m-%dT%H:%M:%S%z >/dev/null 2>&1; then
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%S%z)"
  else
    echo "started=$(date)"
  fi
  echo "count=${COUNT}"
  echo "delay=${DELAY}"
} > "${OUT_DIR}/manifest.txt"

echo "Writing dumps to ${OUT_DIR}"

while [[ "$COUNT" -gt 0 ]]; do
  TS=$(date +%s.%N)
  "${JSTACK_CMD[@]}" > "${OUT_DIR}/jstack.${PID}.${TS}" 2> "${OUT_DIR}/jstack.${PID}.${TS}.err" || true
  "${TOP_CMD[@]}" > "${OUT_DIR}/top.${PID}.${TS}" 2> "${OUT_DIR}/top.${PID}.${TS}.err" || true
  ps -p "$PID" -o pid,ppid,pcpu,pmem,etime,cmd > "${OUT_DIR}/ps.${PID}.${TS}" 2>/dev/null || true
  sleep "$DELAY"
  COUNT=$((COUNT - 1))
  echo -n "."
done
echo
