#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x2-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x2-cluster-b.env}"

WALLET_A="${WALLET_A:-0x1100000000000000000000000000000000000000}"
WALLET_B="${WALLET_B:-0x8800000000000000000000000000000000000000}"

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
  body_file="$(mktemp)"
  header_file="$(mktemp)"

  local tx_hash
  tx_hash="0x$(openssl rand -hex 32 2>/dev/null || date +%s%N)"

  REQUEST_STATUS="$(curl -s -D "$header_file" -o "$body_file" -w "%{http_code}" \
    -X POST "${base_url}/v1/propose-write" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "walletAddress=${wallet}" \
    -d "ethereumTxHash=${tx_hash}" \
    -d "contentType=page" \
    -d "message=[3x2 smoke] ${label}" \
    -d "signature=0xmocksig" \
    -d "paymentTier=standard" || echo "000")"
  REQUEST_BODY="$(cat "$body_file")"
  REQUEST_LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' "$header_file" | tr -d '\r' | tail -n 1)"

  rm -f "$body_file" "$header_file"
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

assert_one_of() {
  local actual="$1"
  local label="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    if [ "$actual" = "$allowed" ]; then
      echo "✅ ${label}: ${actual}"
      return 0
    fi
  done
  echo "❌ ${label}: expected one of '$*', got '${actual}'"
  exit 1
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

assert_contains() {
  local actual="$1"
  local expected_substring="$2"
  local label="$3"
  case "$actual" in
    *"${expected_substring}"*)
      echo "✅ ${label}: ${actual}"
      ;;
    *)
      echo "❌ ${label}: expected to contain '${expected_substring}', got '${actual}'"
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
      assert_prefix "$location" "http://" "${cluster_name} local write redirect url"
      assert_contains "$location" "/v1/propose-write" "${cluster_name} local write redirect path"
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
IFS='|' read -r A_NAME A_SIZE A_HTTP_BASE A_HTTP_STEP A_OPS_PORT A_RUNTIME_ROOT <<<"$A_INFO"
IFS='|' read -r B_NAME B_SIZE B_HTTP_BASE B_HTTP_STEP B_OPS_PORT B_RUNTIME_ROOT <<<"$B_INFO"

read_cluster_state "$CLUSTER_A_CONFIG" "Cluster A Health" "00-7f" "128"
echo ""
read_cluster_state "$CLUSTER_B_CONFIG" "Cluster B Health" "80-ff" "128"
echo ""

submit_write "http://127.0.0.1:${A_HTTP_BASE}" "$WALLET_A" "local-write-a"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP"

submit_write "http://127.0.0.1:${B_HTTP_BASE}" "$WALLET_A" "foreign-write-a-on-b"
assert_equals "$REQUEST_STATUS" "307" "cluster-b foreign write redirect"
assert_prefix "$REQUEST_LOCATION" "http://127.0.0.1:${A_HTTP_BASE}/v1/propose-write" "cluster-b redirect target"

submit_write "http://127.0.0.1:${B_HTTP_BASE}" "$WALLET_B" "local-write-b"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP"

submit_write "http://127.0.0.1:${A_HTTP_BASE}" "$WALLET_B" "foreign-write-b-on-a"
assert_equals "$REQUEST_STATUS" "307" "cluster-a foreign write redirect"
assert_prefix "$REQUEST_LOCATION" "http://127.0.0.1:${B_HTTP_BASE}/v1/propose-write" "cluster-a redirect target"

echo ""
echo "✅ 3x2 sharding smoke passed."
echo "   Proven: health split, authoritative-store separation, and local-vs-foreign write routing."
