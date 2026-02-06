#!/bin/bash
set -euo pipefail

HOST="${HOST:-http://localhost}"
PORTS=(8091 8092 8093)

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
