# Sharding health gates and shared helpers for the multi-cluster smokes (sourced; bash 3.2;
# sourcing has no side effects). The routing smokes and proposal-surfaces-3x2.sh source it; a
# caller that defines a helper of the same name after sourcing keeps its own.
#
# Kept apart from _cluster_test_lib.sh: that library is single-cluster (it derives PORTS from
# the environment, sources the root guard and defines fetch_json/submit_write with signatures
# that differ from the ones here). The sharding_* gates take explicit ports and only
# read GET /health; the JSON checks live in sharding_health.py.
#
#   sharding_assert_cluster_members NAME PREFIXES MOUNT_COUNT PORT...
#       every member is sharded (enabled, local prefixes, remote mount count, separated
#       authoritative store) and reports the same sharding.configDigest.
#   sharding_wait_mounts_available TIMEOUT_SECONDS PORT...
#       wait until every member reports remoteEndpointsAvailable == remoteEndpointCount.
#       Run it before visibility or absence checks: a member whose remote mount is down
#       answers 404 for remote paths, so "absent everywhere" would pass vacuously.
# Both fail fast when the runtime does not report per-mount health.

SHARDING_HEALTH_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sharding_health.py"
SHARDING_HEALTH_HOST="${SHARDING_HEALTH_HOST:-http://127.0.0.1}"
SHARDING_HEALTH_POLL_SECONDS="${SHARDING_HEALTH_POLL_SECONDS:-1}"

sharding_health_check() {
  local port="$1"
  shift
  { curl -s --max-time 5 "${SHARDING_HEALTH_HOST}:${port}/health" 2>/dev/null || true; } \
    | python3 "$SHARDING_HEALTH_PY" "$@"
}

sharding_assert_cluster_members() {
  local name="$1" prefixes="$2" mount_count="$3" port out rc=0 ref_port="" ref_digest="" divergent="" table=""
  shift 3
  for port in "$@"; do
    rc=0
    out="$(sharding_health_check "$port" member "$prefixes" "$mount_count")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "❌ ${name} port ${port} sharding: ${out}"
      return 1
    fi
    echo "✅ ${name} port ${port} sharding: enabled localPrefixes=${prefixes} remoteMountCount=${mount_count} configDigest=${out:0:12}"
    table="${table}     port ${port}: ${out}"$'\n'
    if [ -z "$ref_port" ]; then
      ref_port="$port"
      ref_digest="$out"
    elif [ "$out" != "$ref_digest" ]; then
      divergent="${divergent} ${port}"
    fi
  done
  if [ -n "$divergent" ]; then
    echo "❌ ${name} sharding.configDigest diverges: port(s)${divergent} differ from port ${ref_port}."
    echo "   Members configured identically must report the same digest:"
    printf '%s' "$table"
    return 1
  fi
  echo "✅ ${name} sharding.configDigest identical on all $# members: ${ref_digest}"
}

sharding_wait_mounts_available() {
  local timeout="$1" deadline port out rc pending report
  shift
  deadline=$((SECONDS + timeout))
  while :; do
    pending=""
    report=""
    for port in "$@"; do
      rc=0
      out="$(sharding_health_check "$port" mounts)" || rc=$?
      case "$rc" in
        0) ;;
        3)
          echo "❌ port ${port}: ${out}"
          return 1
          ;;
        *)
          pending="${pending} ${port}"
          report="${report}   port ${port}: ${out}"$'\n'
          ;;
      esac
    done
    if [ -z "$pending" ]; then
      echo "✅ remote mounts available on all $# members (ports $*)"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "❌ remote mounts not all available after ${timeout}s on port(s)${pending}:"
      printf '%s' "$report"
      return 1
    fi
    sleep "$SHARDING_HEALTH_POLL_SECONDS"
  done
}

# Helpers shared verbatim by routing/sharding-3x2-smoke.sh and sharding-3x3-smoke.sh. Defining
# them has no side effects; at call time they read the caller's BASE_CONFIGS, READ_TIMEOUT_SECONDS,
# READ_POLL_INTERVAL_SECONDS, NO_QUORUM_RETRY_*, REQUEST_* and smoke_message (and oak-tx.sh).
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
  form="$(oak_tx_as "$wallet" write --message "$(smoke_message "$label")" --content-type page)" || {
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

  # Remote content is read through this cluster's remote mounts: wait until they are available.
  local ports
  ports="$(cluster_ports "$cluster_size" "$http_base_port" "$http_port_step" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  sharding_wait_mounts_available "$READ_TIMEOUT_SECONDS" $ports || exit 1

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

  # Every member, not just validator-0: one unsharded or differently configured member
  # serves a different shard map. remoteMountCount is a config echo (sanity only); the
  # configDigest comparison and the mount-availability gate below carry the proof.
  local ports
  ports="$(cluster_ports "$cluster_size" "$http_base_port" "$http_port_step" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  sharding_assert_cluster_members "$cluster_name" "$expected_prefixes" "$expected_remote_mounts" $ports || exit 1
}
