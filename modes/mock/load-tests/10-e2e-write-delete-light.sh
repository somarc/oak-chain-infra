#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lightweight defaults for faster lifecycle validation.
export LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/01-light-5min.sh}"
export DELETE_MAX="${DELETE_MAX:-500}"
export DELETE_SLEEP_MS="${DELETE_SLEEP_MS:-30}"
export WAIT_DRAIN_TIMEOUT_SECONDS="${WAIT_DRAIN_TIMEOUT_SECONDS:-1800}"
export WAIT_DRAIN_POLL_SECONDS="${WAIT_DRAIN_POLL_SECONDS:-5}"
export START_CLUSTER_ARGS="${START_CLUSTER_ARGS:---fresh}"

exec "$SCRIPT_DIR/10-e2e-write-delete.sh"
