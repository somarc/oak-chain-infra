#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Heavy profile, but force every proposal to priority tier to stress Aeron path.
TEST_NAME="heavy-30min-priority"
TEST_DURATION_SECONDS=1800
NUM_CLIENTS=15
MIN_WRITES_PER_CLIENT=500
MAX_WRITES_PER_CLIENT=5000
BINARY_PERCENT=20
VALIDATOR_BINARY_PERCENT=30
REGISTER_CLIENTS=true

# 100% priority tier (bypass normal weighted tier mix).
TIER_STANDARD_WEIGHT=0
TIER_EXPRESS_WEIGHT=0
TIER_PRIORITY_WEIGHT=100

source "$SCRIPT_DIR/run-load-test.sh"
