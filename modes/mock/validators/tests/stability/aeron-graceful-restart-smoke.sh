#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILOVER_STOP_MODE=graceful exec "$SCRIPT_DIR/aeron-failover-smoke.sh"
