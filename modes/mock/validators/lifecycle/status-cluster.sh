#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${OAK_CLUSTER_NAME:-single-cluster}"
HOST="${HOST:-http://127.0.0.1}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
VALIDATOR_HTTP_BASE_PORT="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
VALIDATOR_HTTP_PORT_STEP="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
PORTS=()
OPS_PROXY_PORT="${OPS_PROXY_PORT:-8787}"
OPS_PROXY_URL="${OPS_PROXY_URL:-http://127.0.0.1:${OPS_PROXY_PORT}}"
PREVENT_SLEEP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prevent-sleep.sh"
WATCHDOG_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/load-bottleneck-observer.sh"
CLUSTER_RUNTIME_ROOT="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$CLUSTER_RUNTIME_ROOT/cluster-keystore.properties}"
IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"

if [ "$CLUSTER_SIZE" = "5" ]; then
  NODE_COUNT=5
else
  NODE_COUNT=3
fi

for node in $(seq 0 $((NODE_COUNT - 1))); do
  PORTS+=($((VALIDATOR_HTTP_BASE_PORT + (node * VALIDATOR_HTTP_PORT_STEP))))
done

ipfs_process_running() {
  pgrep -f "(ipfs|kubo) daemon" >/dev/null 2>&1
}

echo "cluster:${CLUSTER_NAME} runtime-root=${CLUSTER_RUNTIME_ROOT}"

for port in "${PORTS[@]}"; do
  url="$HOST:$port/health"
  body_file="/tmp/oak-health-$port.json"
  code=$(curl -s -o "$body_file" -w "%{http_code}" "$url" || echo "000")
  if [ "$code" = "000" ] && [ "$HOST" = "http://localhost" ]; then
    # Fallback for environments where localhost resolution/path differs from loopback literal.
    code=$(curl -s -o "$body_file" -w "%{http_code}" "http://127.0.0.1:$port/health" || echo "000")
  fi
  if [ "$code" != "200" ]; then
    echo "validator:$port status=DOWN http=$code"
    continue
  fi
  role=$(python3 - "$body_file" <<'PY'
import json
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
try:
    data = json.loads(p.read_text())
    sharding = data.get('sharding', {}) if isinstance(data, dict) else {}
    fields = [
        data.get('currentRole', 'unknown'),
        str(sharding.get('enabled', False)).lower(),
        str(sharding.get('localPrefixes', 'none')),
        str(sharding.get('remoteMountCount', 0)),
        str(sharding.get('authoritativeStoreSeparated', False)).lower(),
    ]
    print("|".join(fields))
except Exception:
    print('unknown|false|none|0|false')
PY
)
  IFS='|' read -r role sharding_enabled local_prefixes remote_mount_count separated <<<"$role"
  echo "validator:$port status=UP role=$role sharding=$sharding_enabled local-prefixes=$local_prefixes remote-mounts=$remote_mount_count separated=$separated"
done

ipfs_api_code="$(curl -s -X POST -o /tmp/oak-ipfs-api.json -w "%{http_code}" --max-time 2 "$IPFS_API_HTTP/api/v0/version" || echo 000)"
if ipfs_process_running; then
  if [ "$ipfs_api_code" = "200" ]; then
    echo "ipfs:UP api=$IPFS_API_HTTP"
  else
    echo "ipfs:DEGRADED process=UP api=$IPFS_API_HTTP http=$ipfs_api_code"
  fi
else
  if [ "$ipfs_api_code" = "200" ]; then
    echo "ipfs:DEGRADED process=DOWN api=$IPFS_API_HTTP http=200"
  else
    echo "ipfs:DOWN api=$IPFS_API_HTTP http=$ipfs_api_code"
  fi
fi

ops_code=$(curl -s -o /tmp/oak-ops-proxy.json -w "%{http_code}" "$OPS_PROXY_URL/ops/v1/overview" || echo "000")
if [ "$ops_code" = "200" ]; then
  echo "ops-proxy:UP url=$OPS_PROXY_URL"
else
  echo "ops-proxy:DOWN url=$OPS_PROXY_URL http=$ops_code"
fi

if [ -f "$CLUSTER_WALLET_FILE" ]; then
  wallet_addr="$(awk -F'=' '/^walletAddress=/{print $2}' "$CLUSTER_WALLET_FILE" | head -n 1)"
  if [ -n "$wallet_addr" ]; then
    echo "cluster-wallet:UP address=$wallet_addr"
  else
    echo "cluster-wallet:WARN file=$CLUSTER_WALLET_FILE missing-walletAddress"
  fi
else
  echo "cluster-wallet:DOWN file=$CLUSTER_WALLET_FILE"
fi

if [ -x "$PREVENT_SLEEP_SCRIPT" ]; then
  PID_DIR="$CLUSTER_RUNTIME_ROOT/pids" \
    "$PREVENT_SLEEP_SCRIPT" status || echo "sleep-prevention:WARN status-check-failed"
else
  echo "sleep-prevention:UNAVAILABLE script-missing"
fi

if [ -x "$WATCHDOG_SCRIPT" ]; then
  "$WATCHDOG_SCRIPT" --status || true
else
  echo "validator-watchdog:UNAVAILABLE script-missing"
fi

if [ -x "$LOAD_OBSERVER_SCRIPT" ]; then
  "$LOAD_OBSERVER_SCRIPT" --status || true
else
  echo "load-observer:UNAVAILABLE script-missing"
fi
