#!/usr/bin/env bash
# Bootstraps cloud storage resources in floci (AWS) and floci-az (Azure)
# for local oak-segment-consensus development. Run once after docker compose up.
set -euo pipefail

for command_name in curl aws az; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done

FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
FLOCI_AZ_ENDPOINT="${FLOCI_AZ_ENDPOINT:-http://localhost:4577}"

AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

OAK_S3_BUCKET="${OAK_SEGMENT_AWS_BUCKET:-oak-chain-segments}"
OAK_BLOB_BUCKET="${OAK_BLOB_AWS_BUCKET:-oak-chain-blobs}"
OAK_DYNAMO_TABLE="${OAK_SEGMENT_AWS_DYNAMODB_TABLE:-oak-chain-journal}"
OAK_AZ_CONTAINER="${OAK_SEGMENT_AZURE_CONTAINER:-oak-chain-segments}"

wait_for() {
  local url="$1" label="$2"
  echo "Waiting for $label..."
  for i in $(seq 1 30); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  $label is ready"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: $label did not become ready" >&2
  exit 1
}

# ── floci (AWS) ──────────────────────────────────────────────────────────────

wait_for "$FLOCI_ENDPOINT/_floci/health" "floci"

AWS=(aws --endpoint-url="$FLOCI_ENDPOINT")

echo "Creating S3 bucket: $OAK_S3_BUCKET"
if "${AWS[@]}" s3api head-bucket --bucket "$OAK_S3_BUCKET" >/dev/null 2>&1; then
  echo "  (already exists)"
else
  "${AWS[@]}" s3 mb "s3://$OAK_S3_BUCKET"
fi

echo "Creating S3 bucket: $OAK_BLOB_BUCKET"
if "${AWS[@]}" s3api head-bucket --bucket "$OAK_BLOB_BUCKET" >/dev/null 2>&1; then
  echo "  (already exists)"
else
  "${AWS[@]}" s3 mb "s3://$OAK_BLOB_BUCKET"
fi

echo "DynamoDB tables: deferred to Oak so its journal and lock schemas remain authoritative"

# ── floci-az (Azure) ─────────────────────────────────────────────────────────

wait_for "$FLOCI_AZ_ENDPOINT/devstoreaccount1?comp=list" "floci-az"

# Public development-storage credential defined by the emulator. Never use it outside local fixtures.
AZ_CONN="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=$FLOCI_AZ_ENDPOINT/devstoreaccount1;"

echo "Creating Azure Blob container: $OAK_AZ_CONTAINER"
az storage container create \
  --name "$OAK_AZ_CONTAINER" \
  --connection-string "$AZ_CONN" \
  --only-show-errors >/dev/null

echo "Creating Azure Blob container: oak-chain-blobs"
az storage container create \
  --name "oak-chain-blobs" \
  --connection-string "$AZ_CONN" \
  --only-show-errors >/dev/null

echo ""
echo "Emulator resources ready."
echo ""
echo "  AWS (floci):"
echo "    OAK_SEGMENT_BACKEND=aws"
echo "    OAK_SEGMENT_AWS_BUCKET=$OAK_S3_BUCKET"
echo "    OAK_SEGMENT_AWS_DYNAMODB_TABLE=$OAK_DYNAMO_TABLE"
echo "    AWS_ACCESS_KEY_ID=test"
echo "    AWS_SECRET_ACCESS_KEY=test"
echo "    OAK_SEGMENT_AWS_ENDPOINT=$FLOCI_ENDPOINT"
echo "    OAK_BLOB_BACKEND=aws"
echo "    OAK_BLOB_AWS_BUCKET=$OAK_BLOB_BUCKET"
echo "    OAK_BLOB_AWS_ENDPOINT=$FLOCI_ENDPOINT"
echo ""
echo "  Azure (floci-az):"
echo "    OAK_SEGMENT_BACKEND=azure"
echo "    OAK_SEGMENT_AZURE_CONTAINER=$OAK_AZ_CONTAINER"
printf "    OAK_SEGMENT_AZURE_CONNECTION_STRING='%s'\n" "$AZ_CONN"
echo "    OAK_BLOB_BACKEND=azure"
echo "    OAK_BLOB_AZURE_CONTAINER=oak-chain-blobs"
printf "    OAK_BLOB_AZURE_CONNECTION_STRING='%s'\n" "$AZ_CONN"
