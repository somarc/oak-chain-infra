#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Heavy profile, kept under its historical name. It used to force paymentTier=priority, but the
# runtime does not read paymentTier: the tier comes from the settlement proof, so this profile
# no longer differs from the heavy one in tier (see ../TRANSACTION-CONTRACT.md).
TEST_NAME="${TEST_NAME:-heavy-30min-priority}"
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-1800}"
NUM_CLIENTS="${NUM_CLIENTS:-15}"
MIN_WRITES_PER_CLIENT="${MIN_WRITES_PER_CLIENT:-500}"
MAX_WRITES_PER_CLIENT="${MAX_WRITES_PER_CLIENT:-5000}"
BINARY_PERCENT="${BINARY_PERCENT:-20}"
VALIDATOR_BINARY_PERCENT="${VALIDATOR_BINARY_PERCENT:-30}"
REGISTER_CLIENTS="${REGISTER_CLIENTS:-true}"

source "$SCRIPT_DIR/run-load-test.sh"
