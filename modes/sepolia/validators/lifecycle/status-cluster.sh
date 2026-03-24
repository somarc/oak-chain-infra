#!/bin/bash
set -euo pipefail

HOST="${HOST:-http://127.0.0.1}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
PORTS=()
OPS_PROXY_URL="${OPS_PROXY_URL:-http://127.0.0.1:8787}"
PREVENT_SLEEP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prevent-sleep.sh"
WATCHDOG_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/validator-failure-watchdog.sh"
LOAD_OBSERVER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../monitoring/load-bottleneck-observer.sh"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$HOME/oak-chain/cluster-keystore.properties}"
IPFS_API_HTTP="${IPFS_API_HTTP:-http://127.0.0.1:5001}"

if [ "$CLUSTER_SIZE" = "5" ]; then
  PORTS=(8090 8092 8094 8096 8098)
else
  PORTS=(8090 8092 8094)
fi

ipfs_process_running() {
  pgrep -f "(ipfs|kubo) daemon" >/dev/null 2>&1
}

for port in "${PORTS[@]}"; do
  url="$HOST:$port/health"
  body_file="/tmp/oak-health-$port.json"
  code="$(curl -s -o "$body_file" -w "%{http_code}" "$url" || true)"
  [ -n "$code" ] || code="000"
  if [ "$code" = "000" ] && [ "$HOST" = "http://localhost" ]; then
    # Fallback for environments where localhost resolution/path differs from loopback literal.
    code="$(curl -s -o "$body_file" -w "%{http_code}" "http://127.0.0.1:$port/health" || true)"
    [ -n "$code" ] || code="000"
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
    print(data.get('currentRole', 'unknown'))
except Exception:
    print('unknown')
PY
)
  chain_file="/tmp/oak-blockchain-$port.json"
  chain_code="$(curl -s -o "$chain_file" -w "%{http_code}" "$HOST:$port/v1/blockchain/config" || true)"
  [ -n "$chain_code" ] || chain_code="000"
  if [ "$chain_code" = "200" ]; then
    chain_info=$(python3 - "$chain_file" <<'PY'
import json
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
try:
    data = json.loads(p.read_text())
    mode = data.get('mode', 'unknown')
    network = data.get('network', 'unknown')
    contract = data.get('contractAddress', 'n/a')
    print(f"mode={mode} network={network} contract={contract}")
except Exception:
    print("mode=unknown network=unknown contract=n/a")
PY
)
  else
    chain_info="mode=unknown network=unknown contract=n/a"
  fi
  echo "validator:$port status=UP role=$role $chain_info"
done

ipfs_api_code="$(curl -s -X POST -o /tmp/oak-ipfs-api.json -w "%{http_code}" --max-time 2 "$IPFS_API_HTTP/api/v0/version" || true)"
[ -n "$ipfs_api_code" ] || ipfs_api_code="000"
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

ops_code="$(curl -s -o /tmp/oak-ops-proxy.json -w "%{http_code}" "$OPS_PROXY_URL/ops/v1/overview" || true)"
[ -n "$ops_code" ] || ops_code="000"
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
  PID_DIR="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}/pids" \
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
