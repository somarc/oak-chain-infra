#!/bin/bash
set -euo pipefail

HOST="${HOST:-http://localhost}"
PORTS=(8091 8092 8093)
OPS_PROXY_URL="${OPS_PROXY_URL:-http://127.0.0.1:8787}"

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
