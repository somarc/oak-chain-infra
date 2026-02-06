#!/bin/bash
set -euo pipefail

HOST="${HOST:-http://localhost}"
CLUSTER_SIZE="${OAK_CLUSTER_SIZE:-3}"
PORTS=()
OPS_PROXY_URL="${OPS_PROXY_URL:-http://127.0.0.1:8787}"
PREVENT_SLEEP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prevent-sleep.sh"
CLUSTER_WALLET_FILE="${CLUSTER_WALLET_FILE:-$HOME/oak-chain/cluster-keystore.properties}"

if [ "$CLUSTER_SIZE" = "5" ]; then
  PORTS=(8090 8092 8094 8096 8098)
else
  PORTS=(8090 8092 8094)
fi

for port in "${PORTS[@]}"; do
  url="$HOST:$port/health"
  body_file="/tmp/oak-health-$port.json"
  code=$(curl -s -o "$body_file" -w "%{http_code}" "$url" || echo "000")
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
  echo "validator:$port status=UP role=$role"
done

if pgrep -f "ipfs daemon" >/dev/null 2>&1; then
  echo "ipfs:UP"
else
  echo "ipfs:DOWN"
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
  "$PREVENT_SLEEP_SCRIPT" status
else
  echo "sleep-prevention:UNAVAILABLE script-missing"
fi
