# Mock Config

Environment templates used by mock-mode validator lifecycle scripts.

- `mock.env`: mock-chain defaults
- `ipfs.env`: local IPFS endpoint defaults (API `127.0.0.1:5001`, gateway `127.0.0.1:5080`, kept off every validator port; see `../TROUBLESHOOTING.md`)
- `3x2-common.env`: shared 3x2 defaults for both clusters
- `3x2-cluster-a.env`: dual-cluster topology config for cluster A
- `3x2-cluster-b.env`: dual-cluster topology config for cluster B

These files are local development seeds and should be copied to local overrides for machine-specific values.
