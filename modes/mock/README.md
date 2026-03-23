# Mock Mode

Mock mode is local-only and focused on validator lifecycle + IPFS daemon operations.

## Included

- `validators/`
  - local startup/teardown scripts
  - additive 3x2 dual-cluster sharding wrappers
  - troubleshooting notes for local Aeron collisions and sharding bring-up
  - validator debug helpers
  - monitoring utilities
  - validation/test scripts
  - mock + ipfs env configuration
- `load-tests/`
  - smoke/light/medium/heavy/soak load profiles
  - queue samplers and metrics monitors

## Excluded by Design

- Sling starter orchestration
- EDS site startup/stopping scripts
- SDK build/setup pipelines
