# Mock Config

Environment templates used by mock-mode validator lifecycle scripts.

- `mock.env`: mock-chain defaults
- `ipfs.env`: local IPFS endpoint defaults (API `127.0.0.1:5001`, gateway `127.0.0.1:5080`, kept off every validator port; see `../TROUBLESHOOTING.md`)
- `3x2-common.env`: shared 3x2 defaults for both clusters
- `3x2-cluster-a.env`: dual-cluster topology config for cluster A
- `3x2-cluster-b.env`: dual-cluster topology config for cluster B
- `fed-3x2-common.env`: enterprise-federation 3x2 defaults: federation root `$FED_3X2_ROOT` (default `$HOME/oak-chain-federation/3x2`; sourcing fails for any root at, under or above `$HOME/oak-chain`), shared directory file, enterprise ids, `AUTO_START_IPFS=false`
- `fed-3x2-cluster-a.env`: federation cluster A, enterprise `0xa1…a1`, HTTP 8290 (step 2), Aeron 9800, OPS proxy 8797
- `fed-3x2-cluster-b.env`: federation cluster B, enterprise `0xb2…b2`, HTTP 8390 (step 2), Aeron 10200, OPS proxy 8798

The federation packs carry `-Doak.federation.*` flags (mode `mock`, registry `static`, the shared
directory file, `pollMs` 2000) and no `oak.sharding.*` routes: the committed directory decides
ownership and mounts. Their ports avoid the long-lived cluster (8090-8095, 8787, 9000-9206), the
3x2 sharding pack, IPFS (5001, 5080) and 8080/8081/8088/8099, but reuse cluster C's ports in the
3x3 and 5x3x3 packs (8290, 9800): do not run them together (start-fed-3x2.sh refuses ports held by
another root).

These files are local development seeds and should be copied to local overrides for machine-specific values.
