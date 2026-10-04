#!/bin/bash
set -e

LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
VALIDATOR_URL="${VALIDATOR_URL:-http://localhost:8090}"
HTTP_MAX_REDIRECTS="${HTTP_MAX_REDIRECTS:-5}"
HTTP_CONNECT_TIMEOUT_SECONDS="${HTTP_CONNECT_TIMEOUT_SECONDS:-3}"
HTTP_REQUEST_TIMEOUT_SECONDS="${HTTP_REQUEST_TIMEOUT_SECONDS:-30}"

mkdir -p "$LOG_DIR"

# Transactions come from the shared conformant builder `oak-chain tx` (modes/mock/lib/oak-tx.sh,
# contract in modes/mock/TRANSACTION-CONTRACT.md). Client N signs with test key N
# (`oak-chain tx key --index N`), so WALLETS[N-1] is a wallet we hold the key for.
# shellcheck source=../lib/oak-tx.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/oak-tx.sh"
WALLETS=()
while read -r _wallet_role _wallet_address _wallet_index; do
    case "$_wallet_role" in
        client-*) WALLETS+=("$_wallet_address") ;;
    esac
done < "$OAK_TX_WALLETS_FILE"
unset _wallet_role _wallet_address _wallet_index

BINARY_FILES=()

init_binary_files() {
    local workspace_root="$1"
    local candidates=(
        "${workspace_root}/oak-chain-infra/fixtures/binaries/do-it-live.jpeg"
        "${workspace_root}/oak-chain-infra/fixtures/binaries/rickrubin.jpeg"
        "${workspace_root}/oak-chain-docs/public/oak-chain-logo.jpeg"
    )
    BINARY_FILES=()
    for path in "${candidates[@]}"; do
        if [ -f "$path" ]; then
            BINARY_FILES+=("$path")
        fi
    done
}

log_line() {
    local log_file="$1"
    shift
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$log_file"
}

random_int() {
    local min=$1
    local max=$2
    echo $((RANDOM % (max - min + 1) + min))
}

pick_binary_file() {
    local count=${#BINARY_FILES[@]}
    if [ "$count" -eq 0 ]; then
        echo ""
        return
    fi
    local idx=$((RANDOM % count))
    echo "${BINARY_FILES[$idx]}"
}

curl_follow_redirects() {
    curl \
        --location \
        --max-redirs "$HTTP_MAX_REDIRECTS" \
        --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" \
        --max-time "$HTTP_REQUEST_TIMEOUT_SECONDS" \
        --post301 \
        --post302 \
        --post303 \
        "$@"
}

curl_http_code() {
    local output_file="$1"
    shift

    local http_code
    if http_code=$(curl_follow_redirects "$@" -o "$output_file" -w "%{http_code}" 2>/dev/null); then
        printf '%s' "$http_code"
    else
        printf '000'
    fi
}

# Leader discovery from each validator's own /health currentRole. Never use the OPS overview's
# leader: it defaults to node 0 and is wrong whenever another node leads. Prints the leader's
# base URL; returns 1 when no node reports LEADER. Geometry comes from the usual env vars.
find_leader_url() {
    local host="${LEADER_DISCOVERY_HOST:-http://127.0.0.1}"
    local size="${OAK_CLUSTER_SIZE:-3}"
    local base="${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}"
    local step="${OAK_VALIDATOR_HTTP_PORT_STEP:-2}"
    local node=0 port role
    while [ "$node" -lt "$size" ]; do
        port=$((base + node * step))
        role=$(curl -s --max-time 2 "${host}:${port}/health" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("currentRole") or "")
except Exception:
    print("")' 2>/dev/null || true)
        if [ "$role" = "LEADER" ]; then
            printf '%s:%s\n' "$host" "$port"
            return 0
        fi
        node=$((node + 1))
    done
    return 1
}

# "node port" of the current leader (find_leader_url), or "-1 0" and status 1 when none.
leader_node_and_port() {
    local url port
    if ! url="$(find_leader_url)"; then
        echo "-1 0"
        return 1
    fi
    port="${url##*:}"
    echo "$(( (port - ${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}) / ${OAK_VALIDATOR_HTTP_PORT_STEP:-2} )) ${port}"
}

# One conformant delete proposal (modes/mock/TRANSACTION-CONTRACT.md) from `oak-chain tx delete`:
# a fresh 0x+64-hex proposalId, ethereumTxHash = proposalId (mock settlement), and a signature by
# the wallet's test key over exactly contentPath. The wallet must be one we hold (WALLETS or a
# shard-prefix test wallet); otherwise nothing is sent, the reason goes to out_file and stderr,
# and the code is 000, so replay loops count it as a failure and continue. Follows a
# follower's 307 to the leader; curl keeps POST and the body on 307/308 (and on 301/302/303
# via --post30x in curl_follow_redirects). Prints the final HTTP code; body goes to out_file.
submit_delete_proposal() {
    local base_url="$1"
    local wallet="$2"
    local content_path="$3"
    local out_file="$4"
    local form
    if ! form="$(oak_tx_as "$wallet" delete --content-path "$content_path")"; then
        printf '{"error":"no test key held for wallet %s; cannot sign the delete"}\n' "$wallet" > "$out_file"
        printf '000'
        return 0
    fi
    curl_http_code "$out_file" -s "${base_url}/v1/propose-delete" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-binary "$form"
}

resolve_current_leader_url() {
    local consensus_json
    consensus_json=$(curl -s --max-time 2 "${VALIDATOR_URL}/v1/consensus/status" 2>/dev/null || true)
    if [ -z "$consensus_json" ]; then
        printf '%s' "$VALIDATOR_URL"
        return
    fi

    local leader_url
    leader_url=$(printf '%s' "$consensus_json" | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get("currentLeader") or ""
print(value if isinstance(value, str) else "")
' 2>/dev/null || true)

    if [ -n "$leader_url" ]; then
        printf '%s' "$leader_url"
    else
        printf '%s' "$VALIDATOR_URL"
    fi
}

register_client() {
    local wallet=$1
    local client_id=$2
    local client_type="${3:-}"
    local register_url
    register_url=$(resolve_current_leader_url)
    local response_file
    response_file=$(mktemp "${TMPDIR:-/tmp}/oak-register-client.XXXXXX")

    # The runtime does not read a signature here (RegistrationHandler: "signature: Optional ... for
    # future verification"), so registration stays unsigned. It persists clientId -> wallet and
    # answers 409 when a clientId comes back with another wallet, so the clientId carries the
    # wallet's first bytes: a cluster that registered client-N with a pre-test-key wallet still
    # accepts the test-key wallet.
    local registered_id="client-${client_id}-${wallet:2:8}"
    local curl_args=(
        -s -X POST "${register_url}/v1/register-client"
        -H "Content-Type: application/x-www-form-urlencoded"
        -d "clientId=${registered_id}"
        -d "clientUrl=http://${registered_id}.local"
        -d "walletAddress=${wallet}"
    )
    if [ -n "$client_type" ]; then
        curl_args+=( -d "clientType=${client_type}" )
    fi

    local http_code
    http_code=$(curl_http_code "$response_file" "${curl_args[@]}")
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "ERROR: client registration failed for ${registered_id} at ${register_url} (HTTP ${http_code}): $(cat "$response_file" 2>/dev/null)" >&2
        rm -f "$response_file"
        return 1
    fi
    rm -f "$response_file"
}
