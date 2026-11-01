# Validator Troubleshooting

## IPFS gateway on a validator port

Each validator binds two HTTP ports: `base + n*step` and `base + 1 + n*step`. In a 5-member
cluster on base `8090` that is `8090`-`8099`; validator-4's second port is `8099`. The local
IPFS gateway used to default to `8099` too, so while the daemon ran, a 5-member topology
(`single-cluster-5`, `5x3`, `5x3x3`) either could not bind validator-4 or was refused by the
`--fresh` root guard ("port 8099 is held by the IPFS daemon").

The gateway default is now `127.0.0.1:5080` (`lifecycle/lib/ipfs-gateway.sh`): next to Kubo's
other ports (swarm `4001`, API `5001`) and outside every validator range (`8090`-`8099`,
`8190`-`8199`, `8290`-`8299`), the OPS proxies (`8787`-`8789`) and Aeron (`9000`-`10006`).
Kubo's own default, `8080`, is avoided because Docker and dev servers commonly hold it.

An existing `~/.ipfs` repo keeps its own `Addresses.Gateway` until it is reconfigured;
`start-cluster.sh` sets the port only when it initializes a new repo. Check it with
`ipfs config Addresses.Gateway`. To move it, stop every cluster that uses the daemon (the
validators' blob store talks to it), stop the daemon, then run:

```bash
ipfs config Addresses.Gateway /ip4/127.0.0.1/tcp/5080
ipfs daemon   # or let start-cluster.sh auto-start it
```

Then relaunch each cluster with `start-cluster.sh` so all its members pick up the `5080` bases
together.

Until then:

- `start-cluster.sh` warns that the validators' local gateway links point elsewhere, and fails
  when the daemon's gateway sits on one of the cluster's own ports (any 5-member cluster on
  base `8090`).
- 3-member clusters still run; to keep the old port for them, export
  `IPFS_GATEWAY_BASE=http://127.0.0.1:8099/ipfs/` and
  `IPFS_LOCAL_GATEWAY_BASE=http://127.0.0.1:8099/ipfs/`.
- `member.sh` restarts members of a cluster launched before this change with the old `8099`
  bases (their launch record has no gateway keys), and refuses an `IPFS_GATEWAY_BASE` in the
  environment that differs from the one the cluster was launched with. `start-cluster.sh`
  refuses the same mismatch while any member of the root is still running.

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
