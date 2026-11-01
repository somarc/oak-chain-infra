#!/usr/bin/env python3
"""Checks on the `sharding` object of one validator's GET /health, read from stdin.

Used by _sharding_health_lib.sh for the multi-cluster smokes.

  member EXPECTED_PREFIXES EXPECTED_REMOTE_MOUNT_COUNT
      exit 0 and print sharding.configDigest when the member is sharded as expected;
      exit 1 and print why not.
  mounts
      exit 0 and print "available/count" when every configured remote endpoint is available;
      exit 1 and print the per-mount state of the unavailable ones.

Both exit 3 when the runtime does not report per-mount health at all.
"""
import json
import re
import sys

REQUIRES = ("/health has no sharding.{field}: this smoke requires oak-segment-consensus with "
            "per-mount health (fix/cluster-of-clusters-phase0)")


def sharding_of(raw):
    try:
        health = json.loads(raw)
    except ValueError:
        return None, "no /health JSON (validator down or not answering)"
    sharding = health.get("sharding") if isinstance(health, dict) else None
    if not isinstance(sharding, dict):
        return None, "/health has no sharding object"
    return sharding, None


def require(sharding, *fields):
    for field in fields:
        if field not in sharding:
            print(REQUIRES.format(field=field))
            sys.exit(3)


def member(sharding, expected_prefixes, expected_mounts):
    if sharding.get("enabled") is not True:
        return f"sharding.enabled is {json.dumps(sharding.get('enabled'))}, expected true"
    if str(sharding.get("localPrefixes")) != expected_prefixes:
        return f"sharding.localPrefixes is {json.dumps(sharding.get('localPrefixes'))}, expected {expected_prefixes}"
    if str(sharding.get("remoteMountCount")) != expected_mounts:
        return f"sharding.remoteMountCount is {json.dumps(sharding.get('remoteMountCount'))}, expected {expected_mounts}"
    if sharding.get("authoritativeStoreSeparated") is not True:
        return "sharding.authoritativeStoreSeparated is not true"
    require(sharding, "configDigest", "remoteMounts")
    digest = sharding.get("configDigest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return f"sharding.configDigest is {json.dumps(digest)}, expected 64 hex characters"
    print(digest)
    return None


def describe(mount):
    return ("{endpoint} [{prefixes}] connected={connected} available={available} circuit={circuit} "
            "revision={revision} lastRefreshAt={refresh} lastError={error}").format(
        endpoint=mount.get("endpoint"),
        prefixes=mount.get("prefixes"),
        connected=json.dumps(mount.get("connected")),
        available=json.dumps(mount.get("available")),
        circuit=mount.get("circuit"),
        revision=json.dumps(mount.get("revision")),
        refresh=json.dumps(mount.get("lastRefreshAt")),
        error=json.dumps(mount.get("lastError")),
    )


def mounts(sharding):
    require(sharding, "remoteMounts", "remoteEndpointCount", "remoteEndpointsAvailable")
    count = sharding.get("remoteEndpointCount")
    available = sharding.get("remoteEndpointsAvailable")
    entries = sharding.get("remoteMounts")
    if not isinstance(count, int) or not isinstance(available, int) or not isinstance(entries, list):
        return "remoteEndpointCount, remoteEndpointsAvailable or remoteMounts has the wrong type"
    if count < 1:
        return "no remote endpoints configured (remoteEndpointCount=0)"
    if available == count:
        print(f"{available}/{count}")
        return None
    lines = [f"{available}/{count} remote endpoints available"]
    lines += ["  " + describe(m) for m in entries if isinstance(m, dict) and m.get("available") is not True]
    return "\n".join(lines)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    sharding, error = sharding_of(sys.stdin.read())
    if error is None:
        if mode == "member" and len(sys.argv) == 4:
            error = member(sharding, sys.argv[2], sys.argv[3])
        elif mode == "mounts":
            error = mounts(sharding)
        else:
            error = "usage: sharding_health.py member PREFIXES COUNT | mounts"
    if error is not None:
        print(error)
        sys.exit(1)


if __name__ == "__main__":
    main()
