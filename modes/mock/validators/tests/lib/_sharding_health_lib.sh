# Sharding health gates for the multi-cluster smokes (sourced; bash 3.2; no side effects).
#
# Kept apart from _cluster_test_lib.sh: that library is single-cluster (it derives PORTS from
# the environment, sources the root guard and defines fetch_json/submit_write with signatures
# the routing smokes define differently). These helpers take explicit ports and only read
# GET /health; the JSON checks live in sharding_health.py.
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
