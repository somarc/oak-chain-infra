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
# Exit budget: the run fails when any client fails (including registration), when no write
# was attempted, or when a rate exceeds its budget. Non-2xx counts 4xx/5xx/000/other, not 429.
MAX_NON_2XX_RATE="${MAX_NON_2XX_RATE:-0.02}"
MAX_429_RATE="${MAX_429_RATE:-0.10}"

source "$SCRIPT_DIR/suite-lib.sh"

EFFECTIVE_VALIDATOR_BINARY_PERCENT="$VALIDATOR_BINARY_PERCENT"
if [ "$ALLOW_SYNTHETIC_IPFS_CIDS" != "true" ]; then
    EFFECTIVE_VALIDATOR_BINARY_PERCENT=100
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_LOG="${LOG_DIR}/${TEST_NAME}-${TIMESTAMP}.log"
CLIENT_PIDS=()
COUNTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oak-load-counts.XXXXXX")"

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
    rm -rf "$COUNTS_DIR"
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
        if ! register_client "$wallet" "$global_client_id" "$client_type"; then
            log_line "$TEST_LOG" "Client-${global_client_id} registration failed; client aborted"
            exit 1
        fi
    fi

    log_line "$TEST_LOG" "Client-${global_client_id} start (wallet: ${wallet:0:10}..., type: ${client_type}), target writes: ${target_writes}"

    # Pre-sign this client's batch in one call to the shared builder (oak-chain tx write --count).
    # Each line is a conformant form body (modes/mock/TRANSACTION-CONTRACT.md): signed by test key
    # N (= this wallet) over exactly its message, ethereumTxHash = proposalId (mock settlement),
    # no paymentTier (the runtime does not read it; the tier comes from the settlement proof).
    local organization="Client${global_client_id}"
    local message_template
    message_template=$(printf '{"title":"Load Test %s-{seq}","body":"write {seq}","tags":["load","client-%s"],"meta":{"client":"%s","proposalId":"{proposalId}","ts":%s},"payload":{"seq":{seq}}}' \
        "$global_client_id" "$global_client_id" "$global_client_id" "$(date +%s)")
    local batch_file
    batch_file="$(mktemp "${TMPDIR:-/tmp}/oak-load-batch.XXXXXX")"
    if ! oak_tx_as "$wallet" write --count "$target_writes" --message "$message_template" \
        --organization "$organization" --content-type page > "$batch_file"; then
        log_line "$TEST_LOG" "Client-${global_client_id} could not pre-sign its batch; client aborted"
        rm -f "$batch_file"
        exit 1
    fi
    local signed_txs=()
    local tx_line
    while IFS= read -r tx_line; do
        signed_txs+=("$tx_line")
    done < "$batch_file"
    rm -f "$batch_file"

    local end_time=$(( $(date +%s) + TEST_DURATION_SECONDS ))
    local write_count=0
    local ok_count=0
    local fail_count=0
    local fail_429=0
    local fail_4xx=0
    local fail_5xx=0
    local fail_000=0
    local fail_other=0
    local synthetic_rejected=0
    local synthetic_accepted=0
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

        local form="${signed_txs[$((write_count - 1))]}"
        local proposal_id
        proposal_id="$(oak_tx_form_field "$form" proposalId)"

        local do_binary=$((RANDOM % 100))
        local use_binary=0
        if [ "$do_binary" -lt "$BINARY_PERCENT" ]; then
            use_binary=1
        fi

        local curl_args=()
        local http_code
        local synthetic_cid=0

        if [ "$use_binary" -eq 1 ]; then
            local validator_binary=$((RANDOM % 100))
            if [ "$validator_binary" -lt "$EFFECTIVE_VALIDATOR_BINARY_PERCENT" ]; then
                # Validator-hosted upload: multipart with every signed field as a literal
                # --form-string, plus the binary itself.
                oak_tx_form_to_multipart_args "$form"
                curl_args=(
                    -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                    "${OAK_TX_MULTIPART_ARGS[@]}"
                )
                local binary_file
                binary_file=$(pick_binary_file)
                if [ -n "$binary_file" ]; then
                    curl_args+=( -F "file=@${binary_file}" --form-string "mimeType=$(file -b --mime-type "$binary_file")" )
                fi
            else
                # NEGATIVE PATH (only with ALLOW_SYNTHETIC_IPFS_CIDS=true): a validly signed write
                # that references a synthetic ipfsCid the validator has never seen. Out of contract:
                # the runtime rejects it (403 for non-enterprise clients, 422 for an unknown CID), so
                # a 4xx here is the expected outcome and a 2xx is a finding.
                synthetic_cid=1
                local cid
                cid="bafy$(openssl rand -hex 12)"
                curl_args=(
                    -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                    -H "Content-Type: application/x-www-form-urlencoded"
                    --data-binary "${form}&ipfsCid=${cid}"
                )
            fi
        else
            curl_args=(
                -s -X POST "${VALIDATOR_URL}/v1/propose-write"
                -H "Content-Type: application/x-www-form-urlencoded"
                --data-binary "$form"
            )
        fi

        http_code=$(curl_http_code "$response_file" "${curl_args[@]}")

        if [ "$synthetic_cid" -eq 1 ] && [[ "$http_code" =~ ^4[0-9][0-9]$ ]] && [ "$http_code" != "429" ]; then
            synthetic_rejected=$((synthetic_rejected + 1))
        elif [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            ok_count=$((ok_count + 1))
            if [ "$synthetic_cid" -eq 1 ]; then
                synthetic_accepted=$((synthetic_accepted + 1))
                echo "UNEXPECTED ACCEPT of synthetic ipfsCid write (HTTP ${http_code}): $(cat "$response_file" 2>/dev/null)" >> "$client_log"
            fi
            if [ "$CAPTURE_WRITE_ACCEPTS" = "true" ]; then
                local storage_path
                storage_path=$(jq -r '.storagePath // .data.storagePath // empty' "$response_file" 2>/dev/null || true)
                if [ -n "$storage_path" ]; then
                    jq -nc \
                        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --arg test "$TEST_NAME" \
                        --arg clientId "$global_client_id" \
                        --arg wallet "$wallet" \
                        --arg organization "$organization" \
                        --arg txHash "$(oak_tx_form_field "$form" ethereumTxHash)" \
                        --arg proposalId "$proposal_id" \
                        --arg signature "$(oak_tx_form_field "$form" signature)" \
                        --arg storagePath "$storage_path" \
                        --arg httpCode "$http_code" \
                        '{ts:$ts,test:$test,clientId:$clientId,wallet:$wallet,organization:$organization,ethereumTxHash:$txHash,proposalId:$proposalId,signature:$signature,storagePath:$storagePath,httpCode:$httpCode}' \
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
    echo "$write_count $ok_count $fail_429 $fail_4xx $fail_5xx $fail_000 $fail_other $synthetic_rejected $synthetic_accepted" > "${COUNTS_DIR}/client-${client_id}.counts"
    log_line "$TEST_LOG" "Client-${global_client_id} done: writes=${write_count}, ok=${ok_count}, fail=${fail_count}, http429=${fail_429}, http4xx=${fail_4xx}, http5xx=${fail_5xx}, http000=${fail_000}, other=${fail_other}, synthetic_cid_rejected=${synthetic_rejected}, synthetic_cid_accepted=${synthetic_accepted}"
}

log_line "$TEST_LOG" "Starting ${TEST_NAME}"
log_line "$TEST_LOG" "Validator: ${VALIDATOR_URL}"
log_line "$TEST_LOG" "Clients: ${NUM_CLIENTS}"
log_line "$TEST_LOG" "Writes/client: ${MIN_WRITES_PER_CLIENT}-${MAX_WRITES_PER_CLIENT}"
log_line "$TEST_LOG" "Binary rate: ${BINARY_PERCENT}% (validator-hosted ${EFFECTIVE_VALIDATOR_BINARY_PERCENT}%)"
if [ "$EFFECTIVE_VALIDATOR_BINARY_PERCENT" != "$VALIDATOR_BINARY_PERCENT" ]; then
    log_line "$TEST_LOG" "Synthetic client ipfsCid traffic disabled; validator now requires known CID mappings. ALLOW_SYNTHETIC_IPFS_CIDS=true adds it back as a negative path that expects rejection."
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

# Wait per client so a failed client (registration, crash) is counted, not swallowed.
failed_clients=0
for pid in "${CLIENT_PIDS[@]}"; do
    if ! wait "$pid"; then
        failed_clients=$((failed_clients + 1))
    fi
done

read -r total_writes total_ok total_429 total_4xx total_5xx total_000 total_other total_synthetic_rejected total_synthetic_accepted <<EOF_COUNTS
$(cat "$COUNTS_DIR"/client-*.counts 2>/dev/null | awk '{for (i = 1; i <= 9; i++) t[i] += $i} END {printf "%d %d %d %d %d %d %d %d %d\n", t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9]}')
EOF_COUNTS
total_non_2xx=$((total_4xx + total_5xx + total_000 + total_other))
rates="$(awk -v w="$total_writes" -v n="$total_non_2xx" -v r="$total_429" 'BEGIN {
    if (w > 0) printf "%.4f %.4f", n / w, r / w; else printf "0 0" }')"
non_2xx_rate="${rates% *}"
rate_429="${rates#* }"

reasons=""
[ "$failed_clients" -gt 0 ] && reasons="${reasons}failed_clients=${failed_clients};"
[ "$total_writes" -eq 0 ] && reasons="${reasons}no_writes_attempted;"
if awk -v a="$non_2xx_rate" -v b="$MAX_NON_2XX_RATE" 'BEGIN {exit !(a > b)}'; then
    reasons="${reasons}non_2xx_rate>${MAX_NON_2XX_RATE};"
fi
if awk -v a="$rate_429" -v b="$MAX_429_RATE" 'BEGIN {exit !(a > b)}'; then
    reasons="${reasons}429_rate>${MAX_429_RATE};"
fi
# The synthetic-ipfsCid negative path must be rejected; an acceptance means the runtime let an
# out-of-contract write through.
[ "$total_synthetic_accepted" -gt 0 ] && reasons="${reasons}synthetic_cid_accepted=${total_synthetic_accepted};"
verdict=PASS
[ -n "$reasons" ] && verdict=FAIL

log_line "$TEST_LOG" "LOAD_SUMMARY test=${TEST_NAME} verdict=${verdict} clients=${#CLIENT_PIDS[@]} failed_clients=${failed_clients} writes=${total_writes} ok=${total_ok} http429=${total_429} non2xx=${total_non_2xx} (4xx=${total_4xx} 5xx=${total_5xx} 000=${total_000} other=${total_other}) non2xx_rate=${non_2xx_rate}/${MAX_NON_2XX_RATE} 429_rate=${rate_429}/${MAX_429_RATE} synthetic_cid_rejected=${total_synthetic_rejected} synthetic_cid_accepted=${total_synthetic_accepted}${reasons:+ reasons=${reasons%;}}"
if [ "$verdict" = "FAIL" ]; then
    log_line "$TEST_LOG" "❌ ${TEST_NAME} failed"
    exit 1
fi
log_line "$TEST_LOG" "✅ ${TEST_NAME} complete"
