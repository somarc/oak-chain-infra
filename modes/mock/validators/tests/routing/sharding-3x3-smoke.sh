#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$TESTS_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x3-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x3-cluster-b.env}"
CLUSTER_C_CONFIG="${CLUSTER_C_CONFIG:-$CONFIG_DIR/3x3-cluster-c.env}"

WALLET_A="${WALLET_A:-0x1100000000000000000000000000000000000000}"
WALLET_B="${WALLET_B:-0x7700000000000000000000000000000000000000}"
WALLET_C="${WALLET_C:-0xdd00000000000000000000000000000000000000}"
# Shard-local test wallets (keys we hold): each address selects the held test key with the same
# first byte, i.e. `oak-chain tx key --prefix HH` (modes/mock/lib/oak-tx.sh).
# shellcheck source=../../../lib/oak-tx.sh
source "$TESTS_DIR/../../lib/oak-tx.sh"
WALLET_A="$(test_wallet_for_address "$WALLET_A")"
WALLET_B="$(test_wallet_for_address "$WALLET_B")"
WALLET_C="$(test_wallet_for_address "$WALLET_C")"
READ_TIMEOUT_SECONDS="${READ_TIMEOUT_SECONDS:-45}"
READ_POLL_INTERVAL_SECONDS="${READ_POLL_INTERVAL_SECONDS:-1}"
NO_QUORUM_RETRY_MAX="${NO_QUORUM_RETRY_MAX:-15}"
NO_QUORUM_RETRY_DELAY_SECONDS="${NO_QUORUM_RETRY_DELAY_SECONDS:-2}"

REQUEST_STATUS=""
REQUEST_LOCATION=""
REQUEST_BODY=""

resolve_cluster() {
  local cluster_config="$1"
  (
    set -a
    for cfg in "${BASE_CONFIGS[@]}" "$cluster_config"; do
      if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
      else
        echo "❌ Missing config file: $cfg" >&2
        exit 1
      fi
    done
    set +a
    printf '%s|%s|%s|%s|%s|%s\n' \
      "${OAK_CLUSTER_NAME:-unknown}" \
      "${OAK_CLUSTER_SIZE:-3}" \
      "${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}" \
      "${OAK_VALIDATOR_HTTP_PORT_STEP:-2}" \
      "${OPS_PROXY_PORT:-8787}" \
      "${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
  )
}

extract_json_field() {
  local json="$1"
  local field="$2"
  JSON_INPUT="$json" python3 - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
raw = os.environ.get("JSON_INPUT", "")
try:
    cur = json.loads(raw)
except Exception:
    print("")
    sys.exit(0)

for part in field.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print("")
        sys.exit(0)

if isinstance(cur, bool):
    print(str(cur).lower())
else:
    print("" if cur is None else cur)
PY
}

fetch_json() {
  local url="$1"
  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl -s -o "$body_file" -w "%{http_code}" "$url" || echo "000")"
  local body
  body="$(cat "$body_file")"
  rm -f "$body_file"
  printf '%s\n%s\n' "$code" "$body"
}

submit_write() {
  local base_url="$1"
  local wallet="$2"
  local label="$3"
  local body_file
  local header_file
  local no_quorum_attempt=0
  body_file="$(mktemp)"
  header_file="$(mktemp)"

  # Conformant transaction from the shared builder: signed by the wallet's test key over
  # exactly the message, ethereumTxHash = proposalId. Resent unchanged on no_quorum retries.
  local form
  form="$(oak_tx_as "$wallet" write --message "[3x3 smoke] ${label}" --content-type page)" || {
    echo "❌ could not build a signed write for wallet ${wallet}" >&2
    exit 1
  }

  while :; do
    REQUEST_STATUS="$(curl -s -D "$header_file" -o "$body_file" -w "%{http_code}" \
      -X POST "${base_url}/v1/propose-write" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-binary "$form" || echo "000")"
    REQUEST_BODY="$(cat "$body_file")"
    REQUEST_LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' "$header_file" | tr -d '\r' | tail -n 1)"

    if [ "$REQUEST_STATUS" = "503" ] && [[ "$REQUEST_BODY" == *'"code":"service_unavailable"'* ]] &&
      [[ "$REQUEST_BODY" == *"no_quorum"* ]] && [ "$no_quorum_attempt" -lt "$NO_QUORUM_RETRY_MAX" ]; then
      no_quorum_attempt=$((no_quorum_attempt + 1))
      echo "⏳ ${label}: cluster reported no_quorum (attempt ${no_quorum_attempt}/${NO_QUORUM_RETRY_MAX}), retrying in ${NO_QUORUM_RETRY_DELAY_SECONDS}s"
      sleep "$NO_QUORUM_RETRY_DELAY_SECONDS"
      continue
    fi

    break
  done

  rm -f "$body_file" "$header_file"
}

current_role_on_port() {
  local port="$1"
  local body
  local role
  body="$(curl -s "http://127.0.0.1:${port}/v1/consensus/status" || true)"
  role="$(extract_json_field "$body" "currentRole")"
  if [ -n "$role" ]; then
    printf '%s\n' "$role"
    return 0
  fi

  body="$(curl -s "http://127.0.0.1:${port}/health" || true)"
  extract_json_field "$body" "currentRole"
}

cluster_ports() {
  local cluster_size="$1"
  local http_base_port="$2"
  local http_port_step="$3"
  local node_count=3
  if [ "$cluster_size" = "5" ]; then
    node_count=5
  fi

  local idx
  for ((idx=0; idx<node_count; idx++)); do
    printf '%s\n' $((http_base_port + (idx * http_port_step)))
  done
}

resolve_leader_port() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    local leader_port=""
    local leader_count=0
    local port
    while IFS= read -r port; do
      if [ "$(current_role_on_port "$port")" = "LEADER" ]; then
        leader_port="$port"
        leader_count=$((leader_count + 1))
      fi
    done < <(cluster_ports "$cluster_size" "$http_base_port" "$http_port_step")

    if [ "$leader_count" -eq 1 ] && [ -n "$leader_port" ]; then
      printf '%s\n' "$leader_port"
      return 0
    fi

    sleep "$READ_POLL_INTERVAL_SECONDS"
  done

  echo "❌ ${cluster_name} leader resolution timed out"
  exit 1
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "❌ ${label}: expected '${expected}', got '${actual}'"
    exit 1
  fi
  echo "✅ ${label}: ${actual}"
}

assert_prefix() {
  local actual="$1"
  local expected_prefix="$2"
  local label="$3"
  case "$actual" in
    "${expected_prefix}"*)
      echo "✅ ${label}: ${actual}"
      ;;
    *)
      echo "❌ ${label}: expected prefix '${expected_prefix}', got '${actual}'"
      exit 1
      ;;
  esac
}

assert_loopback_redirect_host() {
  local actual="$1"
  local label="$2"
  case "$actual" in
    http://127.0.0.1:*|http://localhost:*)
      echo "✅ ${label}: ${actual}"
      ;;
    *)
      echo "❌ ${label}: expected loopback redirect host, got '${actual}'"
      exit 1
      ;;
  esac
}

assert_port_in_cluster() {
  local url="$1"
  local base_port="$2"
  local port_step="$3"
  local cluster_size="$4"
  local label="$5"
  local port
  port="$(printf '%s' "$url" | sed -E 's#^https?://[^:/]+:([0-9]+).*$#\1#')"
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "❌ ${label}: could not parse redirect port from '${url}'"
    exit 1
  fi

  local node_count=3
  if [ "$cluster_size" = "5" ]; then
    node_count=5
  fi

  local node_port
  for ((idx=0; idx<node_count; idx++)); do
    node_port=$((base_port + (idx * port_step)))
    if [ "$port" = "$node_port" ]; then
      echo "✅ ${label}: ${url}"
      return 0
    fi
  done

  echo "❌ ${label}: redirect '${url}' is not within cluster ports starting at ${base_port}"
  exit 1
}

assert_local_write_result() {
  local status="$1"
  local location="$2"
  local cluster_name="$3"
  local cluster_size="$4"
  local http_base_port="$5"
  local http_port_step="$6"

  case "$status" in
    200|202)
      echo "✅ ${cluster_name} local write: ${status}"
      ;;
    307)
      assert_loopback_redirect_host "$location" "${cluster_name} local write redirect host"
      case "$location" in
        *"/v1/propose-write") ;;
        *)
          echo "❌ ${cluster_name} local write redirect path: expected /v1/propose-write suffix, got '${location}'"
          exit 1
          ;;
      esac
      assert_port_in_cluster "$location" "$http_base_port" "$http_port_step" "$cluster_size" "${cluster_name} local write redirect target"
      ;;
    *)
      echo "❌ ${cluster_name} local write: expected 200, 202, or 307, got '${status}'"
      if [ -n "$REQUEST_BODY" ]; then
        echo "   body: $REQUEST_BODY"
      fi
      exit 1
      ;;
  esac
}

wallet_contains_message() {
  local port="$1"
  local wallet="$2"
  local expected_message="$3"
  local body
  body="$(curl -s "http://127.0.0.1:${port}/v1/wallets/content?wallet=${wallet}" || true)"
  case "$body" in
    *"\"message\":\"${expected_message}\""*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_wallet_message() {
  local port="$1"
  local wallet="$2"
  local expected_message="$3"
  local label="$4"
  local deadline
  deadline=$((SECONDS + READ_TIMEOUT_SECONDS))

  while [ "$SECONDS" -le "$deadline" ]; do
    if wallet_contains_message "$port" "$wallet" "$expected_message"; then
      echo "✅ ${label}: port=${port}"
      return 0
    fi
    sleep "$READ_POLL_INTERVAL_SECONDS"
  done

  echo "❌ ${label}: timed out waiting for '${expected_message}' on port ${port}"
  local body
  body="$(curl -s "http://127.0.0.1:${port}/v1/wallets/content?wallet=${wallet}" || true)"
  if [ -n "$body" ]; then
    echo "   body: ${body}"
  fi
  exit 1
}

wait_for_cluster_wallet_message() {
  local cluster_name="$1"
  local cluster_size="$2"
  local http_base_port="$3"
  local http_port_step="$4"
  local wallet="$5"
  local expected_message="$6"
  local purpose="$7"
  local port
  while IFS= read -r port; do
    wait_for_wallet_message "$port" "$wallet" "$expected_message" "${cluster_name} ${purpose}"
  done < <(cluster_ports "$cluster_size" "$http_base_port" "$http_port_step")
}

read_cluster_state() {
  local cluster_config="$1"
  local label="$2"
  local expected_prefixes="$3"
  local expected_remote_mounts="$4"
  local resolved
  resolved="$(resolve_cluster "$cluster_config")"
  IFS='|' read -r cluster_name cluster_size http_base_port http_port_step ops_port runtime_root <<<"$resolved"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔎 ${label}: ${cluster_name}"
  echo "   http-base=${http_base_port} ops-port=${ops_port}"
  echo "   runtime-root=${runtime_root}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local result
  result="$(fetch_json "http://127.0.0.1:${http_base_port}/health")"
  local code
  local body
  code="$(printf '%s' "$result" | sed -n '1p')"
  body="$(printf '%s' "$result" | sed -n '2,$p')"

  assert_equals "$code" "200" "${cluster_name} /health"
  assert_equals "$(extract_json_field "$body" "sharding.enabled")" "true" "${cluster_name} sharding.enabled"
  assert_equals "$(extract_json_field "$body" "sharding.localPrefixes")" "$expected_prefixes" "${cluster_name} localPrefixes"
  assert_equals "$(extract_json_field "$body" "sharding.remoteMountCount")" "$expected_remote_mounts" "${cluster_name} remoteMountCount"
  assert_equals "$(extract_json_field "$body" "sharding.authoritativeStoreSeparated")" "true" "${cluster_name} authoritativeStoreSeparated"
}

A_INFO="$(resolve_cluster "$CLUSTER_A_CONFIG")"
B_INFO="$(resolve_cluster "$CLUSTER_B_CONFIG")"
C_INFO="$(resolve_cluster "$CLUSTER_C_CONFIG")"
IFS='|' read -r A_NAME A_SIZE A_HTTP_BASE A_HTTP_STEP A_OPS_PORT A_RUNTIME_ROOT <<<"$A_INFO"
IFS='|' read -r B_NAME B_SIZE B_HTTP_BASE B_HTTP_STEP B_OPS_PORT B_RUNTIME_ROOT <<<"$B_INFO"
IFS='|' read -r C_NAME C_SIZE C_HTTP_BASE C_HTTP_STEP C_OPS_PORT C_RUNTIME_ROOT <<<"$C_INFO"

read_cluster_state "$CLUSTER_A_CONFIG" "Cluster A Health" "00-55" "170"
echo ""
read_cluster_state "$CLUSTER_B_CONFIG" "Cluster B Health" "56-aa" "171"
echo ""
read_cluster_state "$CLUSTER_C_CONFIG" "Cluster C Health" "ab-ff" "171"
echo ""

leader_port="$(resolve_leader_port "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP")"
echo "✅ cluster-a local submit leader: port=${leader_port}"
submit_write "http://127.0.0.1:${leader_port}" "$WALLET_A" "local-write-a"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP"
MESSAGE_A="[3x3 smoke] local-write-a"

submit_write "http://127.0.0.1:${B_HTTP_BASE}" "$WALLET_A" "foreign-write-a-on-b"
assert_equals "$REQUEST_STATUS" "307" "cluster-b foreign write redirect"
assert_loopback_redirect_host "$REQUEST_LOCATION" "cluster-b redirect host"
case "$REQUEST_LOCATION" in
  *"/v1/propose-write") ;;
  *)
    echo "❌ cluster-b redirect path: expected /v1/propose-write suffix, got '${REQUEST_LOCATION}'"
    exit 1
    ;;
esac
assert_port_in_cluster "$REQUEST_LOCATION" "$A_HTTP_BASE" "$A_HTTP_STEP" "$A_SIZE" "cluster-b redirect target"

leader_port="$(resolve_leader_port "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP")"
echo "✅ cluster-b local submit leader: port=${leader_port}"
submit_write "http://127.0.0.1:${leader_port}" "$WALLET_B" "local-write-b"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP"
MESSAGE_B="[3x3 smoke] local-write-b"

submit_write "http://127.0.0.1:${C_HTTP_BASE}" "$WALLET_B" "foreign-write-b-on-c"
assert_equals "$REQUEST_STATUS" "307" "cluster-c foreign write redirect"
assert_loopback_redirect_host "$REQUEST_LOCATION" "cluster-c redirect host"
case "$REQUEST_LOCATION" in
  *"/v1/propose-write") ;;
  *)
    echo "❌ cluster-c redirect path: expected /v1/propose-write suffix, got '${REQUEST_LOCATION}'"
    exit 1
    ;;
esac
assert_port_in_cluster "$REQUEST_LOCATION" "$B_HTTP_BASE" "$B_HTTP_STEP" "$B_SIZE" "cluster-c redirect target"

leader_port="$(resolve_leader_port "cluster-c" "$C_SIZE" "$C_HTTP_BASE" "$C_HTTP_STEP")"
echo "✅ cluster-c local submit leader: port=${leader_port}"
submit_write "http://127.0.0.1:${leader_port}" "$WALLET_C" "local-write-c"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-c" "$C_SIZE" "$C_HTTP_BASE" "$C_HTTP_STEP"
MESSAGE_C="[3x3 smoke] local-write-c"

submit_write "http://127.0.0.1:${A_HTTP_BASE}" "$WALLET_C" "foreign-write-c-on-a"
assert_equals "$REQUEST_STATUS" "307" "cluster-a foreign write redirect"
assert_loopback_redirect_host "$REQUEST_LOCATION" "cluster-a redirect host"
case "$REQUEST_LOCATION" in
  *"/v1/propose-write") ;;
  *)
    echo "❌ cluster-a redirect path: expected /v1/propose-write suffix, got '${REQUEST_LOCATION}'"
    exit 1
    ;;
esac
assert_port_in_cluster "$REQUEST_LOCATION" "$C_HTTP_BASE" "$C_HTTP_STEP" "$C_SIZE" "cluster-a redirect target"

wait_for_cluster_wallet_message "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "$MESSAGE_A" "local wallet visible"
wait_for_cluster_wallet_message "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_A" "$MESSAGE_A" "remote wallet visible"
wait_for_cluster_wallet_message "cluster-c" "$C_SIZE" "$C_HTTP_BASE" "$C_HTTP_STEP" "$WALLET_A" "$MESSAGE_A" "remote wallet visible"

wait_for_cluster_wallet_message "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_B" "$MESSAGE_B" "remote wallet visible"
wait_for_cluster_wallet_message "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "$MESSAGE_B" "local wallet visible"
wait_for_cluster_wallet_message "cluster-c" "$C_SIZE" "$C_HTTP_BASE" "$C_HTTP_STEP" "$WALLET_B" "$MESSAGE_B" "remote wallet visible"

wait_for_cluster_wallet_message "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_C" "$MESSAGE_C" "remote wallet visible"
wait_for_cluster_wallet_message "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_C" "$MESSAGE_C" "remote wallet visible"
wait_for_cluster_wallet_message "cluster-c" "$C_SIZE" "$C_HTTP_BASE" "$C_HTTP_STEP" "$WALLET_C" "$MESSAGE_C" "local wallet visible"

echo ""
echo "✅ 3x3 sharding smoke passed."
echo "   Proven: three authoritative Aeron clusters, pairwise redirect enforcement,"
echo "   and network-wide cross-cluster read visibility across all validator endpoints."
