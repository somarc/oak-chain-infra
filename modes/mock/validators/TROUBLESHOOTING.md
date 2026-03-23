# Validator Troubleshooting

## 3x2 Local Sharding: Aeron Collision Findings

The first local `3x2` sharding proof on `2026-03-22` exposed two separate
collision classes.

### 1. MediaDriver directory collision

Symptom:

- cluster A starts
- cluster B startup then destabilizes or kills cluster A
- validator logs mention stale MediaDriver directories under the default temp
  path, for example `/var/folders/.../aeron-mhess-0-driver`

What this means:

- default Aeron MediaDriver directory naming is only node-id scoped
- that is safe for one local cluster
- it is not safe for two separate local clusters on the same host

Operational rule:

- local multi-cluster runs must set Aeron directory isolation explicitly
- infra-side bookkeeping paths alone are not enough; the JVM must set Aeron’s
  real directory base via `aeron.dir`
- `AERON_DIR_BASE` should be unique per cluster, and `AERON_GLOBAL_TMP_CLEANUP`
  should stay `false` for shared-host `3x2` runs

### 2. Aeron transport port collision

Symptom:

- cluster B fails with `Address already in use`
- the failed ports are still the default Aeron ports, such as:
  - `9001`
  - `9101`
  - `9201`

What this means:

- infra may export `AERON_CLUSTER_BASE_PORT=9400`
- current `oak-segment-consensus` runtime still derives live cluster ports from
  the hardcoded `PORT_BASE = 9000` in
  [AeronClusterTopology.java](/Users/mhess/aem/aem-code/OAK/jackrabbit-oak/oak-segment-consensus/src/main/java/org/apache/jackrabbit/oak/segment/consensus/aeron/AeronClusterTopology.java)

Operational rule:

- local `3x2` on one host remains blocked until `jackrabbit-oak` honors a
  configurable Aeron port base end to end
- the cluster configs now surface `AERON_CLUSTER_BASE_PORT`, but it only works
  once the runtime consumes it consistently

## Infra Rules Going Forward

- Keep `AERON_GLOBAL_TMP_CLEANUP=false` for any multi-cluster local topology.
- Use separate:
  - `CLUSTER_RUNTIME_ROOT`
  - `OAK_CLUSTER_NAME`
  - `OAK_VALIDATOR_HTTP_BASE_PORT`
  - `AERON_DIR_BASE`
  - `OPS_PROXY_PORT`
- Do not assume `AERON_CLUSTER_BASE_PORT` alone gives safe single-host
  isolation until the runtime patch lands in `jackrabbit-oak`.

## Evidence Pointers

- cluster A logs:
  - `~/oak-chain/3x2/cluster-a/logs/validator-0.log`
  - `~/oak-chain/3x2/cluster-a/logs/validator-1.log`
  - `~/oak-chain/3x2/cluster-a/logs/validator-2.log`
- cluster B logs:
  - `~/oak-chain/3x2/cluster-b/logs/validator-0.log`
  - `~/oak-chain/3x2/cluster-b/logs/validator-1.log`
  - `~/oak-chain/3x2/cluster-b/logs/validator-2.log`
- durable memory:
  - [2026-03-22-3x2-media-driver-and-port-collision.md](/Users/mhess/aem/aem-code/OAK/meta/context-spine/sessions/2026-03-22-3x2-media-driver-and-port-collision.md)

## Next Fix

Patch `jackrabbit-oak` so Aeron topology no longer hardcodes `9000` as the
global local port base for every cluster on the same machine.
