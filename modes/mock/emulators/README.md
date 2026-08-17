# Local Cloud Storage Emulators

These services exercise the AWS and Azure storage adapters without using cloud accounts. They are development fixtures only; they are not a production topology or a mainnet credential model.

## Prerequisites

- Docker with Compose
- AWS CLI
- Azure CLI

## Start and initialize

```bash
cd modes/mock/emulators
docker compose up -d
./init-emulators.sh
```

The initializer is idempotent and prints the environment needed to point a validator at either backend. The AWS `test` credentials and Azure development storage key are fixed emulator credentials and must never be reused outside loopback development.

The default images are pinned to tested multi-architecture digests. Override either image when deliberately validating a newer emulator release:

```bash
FLOCI_IMAGE=floci/floci:<version> \
FLOCI_AZ_IMAGE=floci/floci-az:<version> \
docker compose up -d
```

For parallel worktrees, override the loopback host ports and use a distinct Compose project name:

```bash
COMPOSE_PROJECT_NAME=oak-emulators-review \
FLOCI_PORT=5566 \
FLOCI_AZ_PORT=5577 \
docker compose up -d
```

Stop the services while preserving their named volumes:

```bash
docker compose down
```

Remove all emulator data:

```bash
docker compose down -v
```
