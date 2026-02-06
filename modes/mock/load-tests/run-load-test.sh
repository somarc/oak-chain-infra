#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Defaults
TEST_NAME="${TEST_NAME:-load-test}"
VALIDATOR_URL="${VALIDATOR_URL:-http://localhost:8090}"
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-300}"
NUM_CLIENTS="${NUM_CLIENTS:-5}"
MIN_WRITES_PER_CLIENT="${MIN_WRITES_PER_CLIENT:-50}"
MAX_WRITES_PER_CLIENT="${MAX_WRITES_PER_CLIENT:-300}"
BINARY_PERCENT="${BINARY_PERCENT:-5}"
VALIDATOR_BINARY_PERCENT="${VALIDATOR_BINARY_PERCENT:-30}"
SLEEP_MIN_MS="${SLEEP_MIN_MS:-50}"
SLEEP_MAX_MS="${SLEEP_MAX_MS:-250}"
REGISTER_CLIENTS="${REGISTER_CLIENTS:-true}"

source "$SCRIPT_DIR/suite-lib.sh"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_LOG="${LOG_DIR}/${TEST_NAME}-${TIMESTAMP}.log"
CLIENT_PIDS=()

init_binary_files "$WORKSPACE_ROOT"

cleanup() {
    log_line "$TEST_LOG" "Cleaning up..."
    for pid in "${CLIENT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

run_client() {
    local client_id=$1
    local wallet="${WALLETS[$((client_id - 1))]}"
    local client_log="${LOG_DIR}/${TEST_NAME}-client-${client_id}-${TIMESTAMP}.log"
    local target_writes
    target_writes=$(random_int "$MIN_WRITES_PER_CLIENT" "$MAX_WRITES_PER_CLIENT")

    if [ "$REGISTER_CLIENTS" = "true" ]; then
        register_client "$wallet" "$client_id"
    fi

    log_line "$TEST_LOG" "Client-${client_id} start (wallet: ${wallet:0:10}...), target writes: ${target_writes}"

    local end_time=$(( $(date +%s) + TEST_DURATION_SECONDS ))
    local write_count=0
    local ok_count=0
    local fail_count=0

    while [ "$(date +%s)" -lt "$end_time" ] && [ "$write_count" -lt "$target_writes" ]; do
        write_count=$((write_count + 1))

        local message_json
        message_json=$(printf '{"title":"Load Test %s-%s","body":"write %s","tags":["load","client-%s"],"meta":{"client":"%s","ts":%s},"payload":{"seq":%s}}' \
            "$client_id" "$write_count" "$write_count" "$client_id" "$client_id" "$(date +%s)" "$write_count")

        local signature
        signature=$(random_hex 65)
        local tx_hash
        tx_hash=$(random_hex 16)

        local tier
        tier=$(select_payment_tier)

        local do_binary=$((RANDOM % 100))
        local use_binary=0
        if [ "$do_binary" -lt "$BINARY_PERCENT" ]; then
            use_binary=1
        fi

        local curl_args=()
        local http_code

        if [ "$use_binary" -eq 1 ]; then
            local validator_binary=$((RANDOM % 100))
            if [ "$validator_binary" -lt "$VALIDATOR_BINARY_PERCENT" ]; then
                tier="priority"
                curl_args=(
                    -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                    -F "walletAddress=${wallet}"
                    -F "signature=${signature}"
                    -F "message=${message_json}"
                    -F "contentType=page"
                    -F "ethereumTxHash=${tx_hash}"
                    -F "paymentTier=${tier}"
                    -F "organization=Client${client_id}"
                )
                local binary_file
                binary_file=$(pick_binary_file)
                if [ -n "$binary_file" ]; then
                    curl_args+=( -F "file=@${binary_file}" -F "mimeType=$(file -b --mime-type "$binary_file")" )
                fi
            else
                local cid
                cid="bafy$(openssl rand -hex 12)"
                curl_args=(
                    -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                    -H "Content-Type: application/x-www-form-urlencoded"
                    -d "walletAddress=${wallet}"
                    -d "signature=${signature}"
                    -d "message=${message_json}"
                    -d "contentType=page"
                    -d "ethereumTxHash=${tx_hash}"
                    -d "paymentTier=${tier}"
                    -d "organization=Client${client_id}"
                    -d "ipfsCid=${cid}"
                )
            fi
        else
            curl_args=(
                -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                -H "Content-Type: application/x-www-form-urlencoded"
                -d "walletAddress=${wallet}"
                -d "signature=${signature}"
                -d "message=${message_json}"
                -d "contentType=page"
                -d "ethereumTxHash=${tx_hash}"
                -d "paymentTier=${tier}"
                -d "organization=Client${client_id}"
            )
        fi

        http_code=$(curl "${curl_args[@]}" -o "/tmp/lt-${TEST_NAME}-${client_id}-$$.json" -w "%{http_code}" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + 1))
            echo "HTTP ${http_code}: $(cat /tmp/lt-${TEST_NAME}-${client_id}-$$.json 2>/dev/null)" >> "$client_log"
        fi

        local sleep_ms
        sleep_ms=$(random_int "$SLEEP_MIN_MS" "$SLEEP_MAX_MS")
        sleep "$(awk "BEGIN {print ${sleep_ms}/1000}")"
    done

    log_line "$TEST_LOG" "Client-${client_id} done: writes=${write_count}, ok=${ok_count}, fail=${fail_count}"
}

log_line "$TEST_LOG" "Starting ${TEST_NAME}"
log_line "$TEST_LOG" "Validator: ${VALIDATOR_URL}"
log_line "$TEST_LOG" "Clients: ${NUM_CLIENTS}"
log_line "$TEST_LOG" "Writes/client: ${MIN_WRITES_PER_CLIENT}-${MAX_WRITES_PER_CLIENT}"
log_line "$TEST_LOG" "Binary rate: ${BINARY_PERCENT}% (validator-hosted ${VALIDATOR_BINARY_PERCENT}%)"
log_line "$TEST_LOG" "Duration: ${TEST_DURATION_SECONDS}s"

if [ "$NUM_CLIENTS" -gt "${#WALLETS[@]}" ]; then
    log_line "$TEST_LOG" "ERROR: NUM_CLIENTS exceeds available wallet count (${#WALLETS[@]})."
    exit 1
fi

for i in $(seq 1 "$NUM_CLIENTS"); do
    run_client "$i" &
    CLIENT_PIDS+=("$!")
    sleep 0.1
  
    if [ "$TEST_NAME" = "smoke-one-write" ]; then
        break
    fi
done

wait
log_line "$TEST_LOG" "✅ ${TEST_NAME} complete"
