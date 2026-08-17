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
ALLOW_SYNTHETIC_IPFS_CIDS="${ALLOW_SYNTHETIC_IPFS_CIDS:-false}"
SLEEP_MIN_MS="${SLEEP_MIN_MS:-50}"
SLEEP_MAX_MS="${SLEEP_MAX_MS:-250}"
REGISTER_CLIENTS="${REGISTER_CLIENTS:-true}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
MAX_429_BODY_SAMPLES_PER_CLIENT="${MAX_429_BODY_SAMPLES_PER_CLIENT:-3}"
MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT="${MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT:-20}"
FAIL_SUMMARY_INTERVAL="${FAIL_SUMMARY_INTERVAL:-500}"
CAPTURE_WRITE_ACCEPTS="${CAPTURE_WRITE_ACCEPTS:-false}"
CAPTURE_WRITE_ACCEPTS_DIR="${CAPTURE_WRITE_ACCEPTS_DIR:-}"

source "$SCRIPT_DIR/suite-lib.sh"

EFFECTIVE_VALIDATOR_BINARY_PERCENT="$VALIDATOR_BINARY_PERCENT"
if [ "$ALLOW_SYNTHETIC_IPFS_CIDS" != "true" ]; then
    EFFECTIVE_VALIDATOR_BINARY_PERCENT=100
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_LOG="${LOG_DIR}/${TEST_NAME}-${TIMESTAMP}.log"
CLIENT_PIDS=()

if [ "$CAPTURE_WRITE_ACCEPTS" = "true" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: CAPTURE_WRITE_ACCEPTS=true requires jq on PATH."
        exit 1
    fi
    if [ -z "$CAPTURE_WRITE_ACCEPTS_DIR" ]; then
        CAPTURE_WRITE_ACCEPTS_DIR="${LOG_DIR}/${TEST_NAME}-accepted-${TIMESTAMP}"
    fi
    mkdir -p "$CAPTURE_WRITE_ACCEPTS_DIR"
fi

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
    local global_client_id=$((client_id + CLIENT_ID_OFFSET))
    local wallet="${WALLETS[$((global_client_id - 1))]}"
    local client_log="${LOG_DIR}/${TEST_NAME}-client-${client_id}-${TIMESTAMP}.log"
    local target_writes
    target_writes=$(random_int "$MIN_WRITES_PER_CLIENT" "$MAX_WRITES_PER_CLIENT")
    local client_type="${REGISTER_CLIENT_TYPE:-}"
    if [ -z "$client_type" ]; then
        if [ "$BINARY_PERCENT" -gt 0 ] && [ "$EFFECTIVE_VALIDATOR_BINARY_PERCENT" -lt 100 ]; then
            client_type="enterprise"
        else
            client_type="supply-chain"
        fi
    fi

    if [ "$REGISTER_CLIENTS" = "true" ]; then
        register_client "$wallet" "$global_client_id" "$client_type"
    fi

    log_line "$TEST_LOG" "Client-${global_client_id} start (wallet: ${wallet:0:10}..., type: ${client_type}), target writes: ${target_writes}"

    local end_time=$(( $(date +%s) + TEST_DURATION_SECONDS ))
    local write_count=0
    local ok_count=0
    local fail_count=0
    local fail_429=0
    local fail_4xx=0
    local fail_5xx=0
    local fail_000=0
    local fail_other=0
    local sample_429=0
    local sample_other=0
    local capture_file=""
    local response_file="/tmp/lt-${TEST_NAME}-${client_id}-$$.json"
    if [ "$CAPTURE_WRITE_ACCEPTS" = "true" ]; then
        capture_file="${CAPTURE_WRITE_ACCEPTS_DIR}/client-${client_id}.ndjson"
        : > "$capture_file"
    fi

    while [ "$(date +%s)" -lt "$end_time" ] && [ "$write_count" -lt "$target_writes" ]; do
        write_count=$((write_count + 1))

        local signature
        signature=$(random_hex 65)
        local proposal_id
        proposal_id=$(random_hex 32)
        local tx_hash
        tx_hash="$proposal_id"

        local message_json
        message_json=$(printf '{"title":"Load Test %s-%s","body":"write %s","tags":["load","client-%s"],"meta":{"client":"%s","proposalId":"%s","ts":%s},"payload":{"seq":%s}}' \
            "$global_client_id" "$write_count" "$write_count" "$global_client_id" "$global_client_id" "$proposal_id" "$(date +%s)" "$write_count")

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
            if [ "$validator_binary" -lt "$EFFECTIVE_VALIDATOR_BINARY_PERCENT" ]; then
                tier="priority"
                curl_args=(
                    -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                    -F "walletAddress=${wallet}"
                    -F "signature=${signature}"
                    -F "message=${message_json}"
                    -F "contentType=page"
                    -F "proposalId=${proposal_id}"
                    -F "ethereumTxHash=${tx_hash}"
                    -F "paymentTier=${tier}"
                    -F "organization=Client${global_client_id}"
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
                    -d "proposalId=${proposal_id}"
                    -d "ethereumTxHash=${tx_hash}"
                    -d "paymentTier=${tier}"
                    -d "organization=Client${global_client_id}"
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
                -d "proposalId=${proposal_id}"
                -d "ethereumTxHash=${tx_hash}"
                -d "paymentTier=${tier}"
                -d "organization=Client${global_client_id}"
            )
        fi

        http_code=$(curl_http_code "$response_file" "${curl_args[@]}")

        if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
            ok_count=$((ok_count + 1))
            if [ "$CAPTURE_WRITE_ACCEPTS" = "true" ]; then
                local storage_path
                storage_path=$(jq -r '.storagePath // .data.storagePath // empty' "$response_file" 2>/dev/null || true)
                if [ -n "$storage_path" ]; then
                    jq -nc \
                        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --arg test "$TEST_NAME" \
                        --arg clientId "$global_client_id" \
                        --arg wallet "$wallet" \
                        --arg organization "Client${global_client_id}" \
                        --arg tier "$tier" \
                        --arg txHash "$tx_hash" \
                        --arg proposalId "$(jq -r '.proposalId // .data.proposalId // empty' "$response_file" 2>/dev/null || true)" \
                        --arg storagePath "$storage_path" \
                        --arg httpCode "$http_code" \
                        '{ts:$ts,test:$test,clientId:$clientId,wallet:$wallet,organization:$organization,tier:$tier,ethereumTxHash:$txHash,proposalId:$proposalId,storagePath:$storagePath,httpCode:$httpCode}' \
                        >> "$capture_file"
                fi
            fi
        else
            fail_count=$((fail_count + 1))
            case "$http_code" in
                429)
                    fail_429=$((fail_429 + 1))
                    if [ "$sample_429" -lt "$MAX_429_BODY_SAMPLES_PER_CLIENT" ]; then
                        sample_429=$((sample_429 + 1))
                        echo "HTTP ${http_code}: $(cat "$response_file" 2>/dev/null)" >> "$client_log"
                    fi
                    ;;
                4??) fail_4xx=$((fail_4xx + 1)) ;;
                5??) fail_5xx=$((fail_5xx + 1)) ;;
                000) fail_000=$((fail_000 + 1)) ;;
                *) fail_other=$((fail_other + 1)) ;;
            esac
            if [ "$http_code" != "429" ] && [ "$sample_other" -lt "$MAX_OTHER_FAILURE_SAMPLES_PER_CLIENT" ]; then
                sample_other=$((sample_other + 1))
                echo "HTTP ${http_code}: $(cat "$response_file" 2>/dev/null)" >> "$client_log"
            fi
            if [ $((fail_count % FAIL_SUMMARY_INTERVAL)) -eq 0 ]; then
                log_line "$TEST_LOG" "Client-${global_client_id} fail-summary: total=${fail_count} http429=${fail_429} http4xx=${fail_4xx} http5xx=${fail_5xx} http000=${fail_000} other=${fail_other}"
            fi
        fi

        local sleep_ms
        sleep_ms=$(random_int "$SLEEP_MIN_MS" "$SLEEP_MAX_MS")
        sleep "$(awk "BEGIN {print ${sleep_ms}/1000}")"
    done

    {
        echo "HTTP_SUMMARY code=429 count=${fail_429}"
        echo "HTTP_SUMMARY code=4xx count=${fail_4xx}"
        echo "HTTP_SUMMARY code=5xx count=${fail_5xx}"
        echo "HTTP_SUMMARY code=000 count=${fail_000}"
        echo "HTTP_SUMMARY code=other count=${fail_other}"
        echo "HTTP_SUMMARY code=total_fail count=${fail_count}"
    } >> "$client_log"
    rm -f "$response_file"
    log_line "$TEST_LOG" "Client-${global_client_id} done: writes=${write_count}, ok=${ok_count}, fail=${fail_count}, http429=${fail_429}, http4xx=${fail_4xx}, http5xx=${fail_5xx}, http000=${fail_000}, other=${fail_other}"
}

log_line "$TEST_LOG" "Starting ${TEST_NAME}"
log_line "$TEST_LOG" "Validator: ${VALIDATOR_URL}"
log_line "$TEST_LOG" "Clients: ${NUM_CLIENTS}"
log_line "$TEST_LOG" "Writes/client: ${MIN_WRITES_PER_CLIENT}-${MAX_WRITES_PER_CLIENT}"
log_line "$TEST_LOG" "Binary rate: ${BINARY_PERCENT}% (validator-hosted ${EFFECTIVE_VALIDATOR_BINARY_PERCENT}%)"
if [ "$EFFECTIVE_VALIDATOR_BINARY_PERCENT" != "$VALIDATOR_BINARY_PERCENT" ]; then
    log_line "$TEST_LOG" "Synthetic client ipfsCid traffic disabled; validator now requires known CID mappings. Set ALLOW_SYNTHETIC_IPFS_CIDS=true to restore the legacy synthetic-CID path."
fi
log_line "$TEST_LOG" "Duration: ${TEST_DURATION_SECONDS}s"
if [ "$CAPTURE_WRITE_ACCEPTS" = "true" ]; then
    log_line "$TEST_LOG" "Capture accepted writes: true (dir: ${CAPTURE_WRITE_ACCEPTS_DIR})"
fi

if [ $((NUM_CLIENTS + CLIENT_ID_OFFSET)) -gt "${#WALLETS[@]}" ]; then
    log_line "$TEST_LOG" "ERROR: NUM_CLIENTS + CLIENT_ID_OFFSET exceeds available wallet count (${#WALLETS[@]})."
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
