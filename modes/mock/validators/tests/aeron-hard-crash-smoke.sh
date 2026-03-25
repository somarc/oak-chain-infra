#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILOVER_STOP_MODE=crash \
REJOIN_WAIT_SECONDS="${REJOIN_WAIT_SECONDS:-180}" \
POST_REJOIN_SETTLE_SECONDS="${POST_REJOIN_SETTLE_SECONDS:-90}" \
exec "$SCRIPT_DIR/aeron-failover-smoke.sh"
