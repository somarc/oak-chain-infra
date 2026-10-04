#!/usr/bin/env bash
# Shell access to the one conformant transaction builder, `oak-chain tx` (src/tx-cli.mjs).
# Contract: modes/mock/TRANSACTION-CONTRACT.md. Source this file (bash 3.2 compatible).
#
# Every wallet a mock script signs for must be a test key we hold (test-wallets.tsv):
#   - shard-local wallets:  test_wallet_for_prefix HH   (= oak-chain tx key --prefix HH)
#   - load-test client N:   the client-N row             (= oak-chain tx key --index N)
# test_wallet_for_address reads any other address (e.g. a legacy synthetic 0x1100…0 default)
# as a shard selector: it returns the held test key with the same first byte, so it routes to
# the same shard. Distinct roles therefore need distinct first bytes.
#
# OAK_CHAIN_CLI overrides the CLI path; by default it resolves relative to this file.

OAK_TX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OAK_CHAIN_CLI="${OAK_CHAIN_CLI:-$(cd "$OAK_TX_LIB_DIR/../../.." && pwd)/bin/oak-chain.mjs}"
OAK_TX_WALLETS_FILE="${OAK_TX_WALLETS_FILE:-$OAK_TX_LIB_DIR/test-wallets.tsv}"

oak_tx() {
  node "$OAK_CHAIN_CLI" tx "$@"
}

oak_tx_lower() {
  printf '%s' "$1" | tr 'A-F' 'a-f'
}

# Address of a test-wallets.tsv role (client-N or prefix-HH).
oak_test_wallet() {
  local address
  address="$(awk -v role="$1" '$1 == role { print $2; exit }' "$OAK_TX_WALLETS_FILE")"
  if [ -z "$address" ]; then
    echo "ERROR: no test wallet with role '$1' in $OAK_TX_WALLETS_FILE" >&2
    return 1
  fi
  printf '%s\n' "$address"
}

# Held test wallet whose address starts with byte HH (accepts "7f", "0x7f" or a decimal via printf).
test_wallet_for_prefix() {
  local prefix
  prefix="$(oak_tx_lower "${1#0x}")"
  oak_test_wallet "prefix-${prefix}"
}

# The address itself when we hold its key; otherwise the held test key for its first byte.
test_wallet_for_address() {
  local address
  address="$(oak_tx_lower "$1")"
  if oak_tx_key_index "$address" >/dev/null 2>&1; then
    printf '%s\n' "$address"
    return 0
  fi
  case "$address" in
    0x[0-9a-f][0-9a-f]*) test_wallet_for_prefix "${address:2:2}" ;;
    *)
      echo "ERROR: '$1' is not an 0x address; cannot pick a test wallet for it" >&2
      return 1
      ;;
  esac
}

# Key index (for `oak-chain tx … --index`) of a held wallet; fails clearly for any other address.
oak_tx_key_index() {
  local address index
  address="$(oak_tx_lower "$1")"
  index="$(awk -v address="$address" '$2 == address { print $3; exit }' "$OAK_TX_WALLETS_FILE")"
  if [ -z "$index" ]; then
    echo "ERROR: wallet $1 is not a test key we hold ($OAK_TX_WALLETS_FILE). A valid transaction needs a signature by walletAddress; use test_wallet_for_prefix HH or test_wallet_for_address." >&2
    return 1
  fi
  printf '%s\n' "$index"
}

# oak_tx_as WALLET VERB [args...]: `oak-chain tx VERB` signed by WALLET's test key.
oak_tx_as() {
  local wallet="$1" verb="$2" index
  shift 2
  index="$(oak_tx_key_index "$wallet")" || return 1
  oak_tx "$verb" --index "$index" "$@"
}

# One field of an application/x-www-form-urlencoded body, decoded.
oak_tx_form_field() {
  local rest="$1&" pair
  while [ -n "$rest" ]; do
    pair="${rest%%&*}"
    rest="${rest#*&}"
    if [ "${pair%%=*}" = "$2" ]; then
      oak_tx_urldecode "${pair#*=}"
      return 0
    fi
  done
  return 1
}

oak_tx_urldecode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

# Turns a `--format form` body into curl multipart args in the array OAK_TX_MULTIPART_ARGS:
# one `--form-string name=value` per field (literal, unlike -F, which interprets ; @ <).
oak_tx_form_to_multipart_args() {
  local rest="$1&" pair value
  OAK_TX_MULTIPART_ARGS=()
  while [ -n "$rest" ]; do
    pair="${rest%%&*}"
    rest="${rest#*&}"
    [ -n "$pair" ] || continue
    value="${pair#*=}"
    value="${value//+/ }"
    printf -v value '%b' "${value//%/\\x}"
    OAK_TX_MULTIPART_ARGS+=(--form-string "${pair%%=*}=${value}")
  done
}
