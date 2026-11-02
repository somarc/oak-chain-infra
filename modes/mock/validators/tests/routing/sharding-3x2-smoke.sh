#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$TESTS_DIR/../config"
BASE_CONFIGS=("$CONFIG_DIR/mock.env" "$CONFIG_DIR/ipfs.env")
CLUSTER_A_CONFIG="${CLUSTER_A_CONFIG:-$CONFIG_DIR/3x2-cluster-a.env}"
CLUSTER_B_CONFIG="${CLUSTER_B_CONFIG:-$CONFIG_DIR/3x2-cluster-b.env}"

WALLET_A="${WALLET_A:-0x1100000000000000000000000000000000000000}"
WALLET_B="${WALLET_B:-0x8800000000000000000000000000000000000000}"
# Shard-local test wallets (keys we hold): each address selects the held test key with the same
# first byte, i.e. `oak-chain tx key --prefix HH` (modes/mock/lib/oak-tx.sh).
# shellcheck source=../../../lib/oak-tx.sh
source "$TESTS_DIR/../../lib/oak-tx.sh"
# shellcheck source=../lib/_sharding_health_lib.sh
source "$TESTS_DIR/lib/_sharding_health_lib.sh"
WALLET_A="$(test_wallet_for_address "$WALLET_A")"
WALLET_B="$(test_wallet_for_address "$WALLET_B")"
READ_TIMEOUT_SECONDS="${READ_TIMEOUT_SECONDS:-30}"
READ_POLL_INTERVAL_SECONDS="${READ_POLL_INTERVAL_SECONDS:-1}"
NO_QUORUM_RETRY_MAX="${NO_QUORUM_RETRY_MAX:-15}"
NO_QUORUM_RETRY_DELAY_SECONDS="${NO_QUORUM_RETRY_DELAY_SECONDS:-2}"
# Every write message carries this run's nonce, so a rerun on a reused runtime root cannot pass
# on content an earlier run left behind.
SMOKE_RUN_NONCE="${SMOKE_RUN_NONCE:-$(date +%Y%m%dT%H%M%S)-$$-${RANDOM}}"

smoke_message() {
  printf '[3x2 smoke %s] %s' "$SMOKE_RUN_NONCE" "$1"
}

REQUEST_STATUS=""
REQUEST_LOCATION=""
REQUEST_BODY=""

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

A_INFO="$(resolve_cluster "$CLUSTER_A_CONFIG")"
B_INFO="$(resolve_cluster "$CLUSTER_B_CONFIG")"
IFS='|' read -r A_NAME A_SIZE A_HTTP_BASE A_HTTP_STEP A_OPS_PORT A_RUNTIME_ROOT <<<"$A_INFO"
IFS='|' read -r B_NAME B_SIZE B_HTTP_BASE B_HTTP_STEP B_OPS_PORT B_RUNTIME_ROOT <<<"$B_INFO"

read_cluster_state "$CLUSTER_A_CONFIG" "Cluster A Health" "00-7f" "128"
echo ""
read_cluster_state "$CLUSTER_B_CONFIG" "Cluster B Health" "80-ff" "128"
echo ""
# No routing or visibility assertion until every member of every cluster can reach its remote
# mounts; an unavailable mount makes remote reads fail (and absence checks pass vacuously).
ALL_PORTS=""
ALL_PORTS="${ALL_PORTS} $(cluster_ports "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" | tr '\n' ' ')"
ALL_PORTS="${ALL_PORTS} $(cluster_ports "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" | tr '\n' ' ')"
# shellcheck disable=SC2086
sharding_wait_mounts_available "$READ_TIMEOUT_SECONDS" $ALL_PORTS || exit 1
echo ""

leader_port="$(resolve_leader_port "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP")"
echo "✅ cluster-a local submit leader: port=${leader_port}"
submit_write "http://127.0.0.1:${leader_port}" "$WALLET_A" "local-write-a"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP"
MESSAGE_A="$(smoke_message "local-write-a")"

submit_write "http://127.0.0.1:${B_HTTP_BASE}" "$WALLET_A" "foreign-write-a-on-b"
assert_equals "$REQUEST_STATUS" "307" "cluster-b foreign write redirect"
assert_prefix "$REQUEST_LOCATION" "http://127.0.0.1:${A_HTTP_BASE}/v1/propose-write" "cluster-b redirect target"

wait_for_cluster_wallet_message "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_A" "$MESSAGE_A" "local wallet visible"
wait_for_cluster_wallet_message "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_A" "$MESSAGE_A" "remote wallet visible"

leader_port="$(resolve_leader_port "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP")"
echo "✅ cluster-b local submit leader: port=${leader_port}"
submit_write "http://127.0.0.1:${leader_port}" "$WALLET_B" "local-write-b"
assert_local_write_result "$REQUEST_STATUS" "$REQUEST_LOCATION" "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP"
MESSAGE_B="$(smoke_message "local-write-b")"

submit_write "http://127.0.0.1:${A_HTTP_BASE}" "$WALLET_B" "foreign-write-b-on-a"
assert_equals "$REQUEST_STATUS" "307" "cluster-a foreign write redirect"
assert_prefix "$REQUEST_LOCATION" "http://127.0.0.1:${B_HTTP_BASE}/v1/propose-write" "cluster-a redirect target"

wait_for_cluster_wallet_message "cluster-b" "$B_SIZE" "$B_HTTP_BASE" "$B_HTTP_STEP" "$WALLET_B" "$MESSAGE_B" "local wallet visible"
wait_for_cluster_wallet_message "cluster-a" "$A_SIZE" "$A_HTTP_BASE" "$A_HTTP_STEP" "$WALLET_B" "$MESSAGE_B" "remote wallet visible"

echo ""
echo "✅ 3x2 sharding smoke passed."
echo "   Proven: every member sharded with one configDigest per cluster, all remote mounts available,"
echo "   authoritative-store separation, local-vs-foreign write routing, and bidirectional"
echo "   cross-cluster read visibility of this run's writes (nonce ${SMOKE_RUN_NONCE}) on every endpoint."
