#!/usr/bin/env bash
set -u
BASES=("http://localhost:8090" "http://localhost:8092" "http://localhost:8094")
PATHS=(
  "/health"
  "/health/cluster"
  "/health/deep"
  "/v1/consensus/status"
  "/v1/head"
  "/v1/proposals/pending/count"
  "/v1/peers"
  "/v1/ngrok-url"
  "/v1/blockchain/config"
  "/v1/aeron/cluster-state"
  "/v1/aeron/raft-metrics"
  "/v1/aeron/node-status"
  "/v1/aeron/leadership-history"
  "/v1/aeron/replication-lag"
  "/v1/events/recent"
  "/v1/events/stats"
  "/api/metrics"
  "/metrics"
  "/manifest"
  "/journal.log"
  "/api/explore?path=/"
  "/api/segments/recent"
  "/api/segments/tars"
  "/v1/wallets/stats"
  "/v1/wallets/content?wallet=0x0000000000000000000000000000000000000000"
  "/v1/gc/estimate"
)

echo "Oak Segment Consensus API smoke check"
for base in "${BASES[@]}"; do
  echo "\n== ${base} =="
  for path in "${PATHS[@]}"; do
    url="${base}${path}"
    : > /tmp/oak_api_body.txt
    status=$(curl -s -o /tmp/oak_api_body.txt -w "%{http_code}" "$url" || true)
    body=$(head -c 120 /tmp/oak_api_body.txt | tr '\n' ' ')
    printf "%3s %-45s %s\n" "$status" "$path" "$body"
  done

done

POSTS=(
  "/v1/propose-write"
  "/v1/propose-delete"
  "/v1/binary/declare-intent"
  "/v1/binary/complete-upload"
  "/v1/register-client"
)

echo "\nPOST endpoint sanity (expect 400/415/503 depending on validation)"
for base in "${BASES[@]}"; do
  echo "\n== ${base} =="
  for path in "${POSTS[@]}"; do
    url="${base}${path}"
    : > /tmp/oak_api_body.txt
    status=$(curl -s -o /tmp/oak_api_body.txt -w "%{http_code}" -X POST "$url" || true)
    body=$(head -c 120 /tmp/oak_api_body.txt | tr '\n' ' ')
    printf "%3s %-45s %s\n" "$status" "$path" "$body"
  done
  dummy="${base}/v1/proposals/does-not-exist/status"
  : > /tmp/oak_api_body.txt
  status=$(curl -s -o /tmp/oak_api_body.txt -w "%{http_code}" "$dummy" || true)
  body=$(head -c 120 /tmp/oak_api_body.txt | tr '\n' ' ')
  printf "%3s %-45s %s\n" "$status" "/v1/proposals/{id}/status" "$body"

done
