#!/usr/bin/env bash

# Helpers shared verbatim by surfaces/proposal-surfaces-single-cluster.sh and
# proposal-surfaces-3x2.sh (sourced; defining them has no side effects). log and fail append
# to the caller's $RUN_LOG, so set RUN_LOG before sourcing; settle_http_idle reads the
# caller's HTTP_IDLE_SETTLE_SECONDS at call time.

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$RUN_LOG"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

normalize_wallet() {
  local wallet="$1"
  wallet="${wallet#0x}"
  printf '%s\n' "$(printf '%s' "$wallet" | tr '[:upper:]' '[:lower:]')"
}

wallet_root_path() {
  local wallet
  wallet="$(normalize_wallet "$1")"
  printf '/oak-chain/%s/%s/%s/0x%s\n' "${wallet:0:2}" "${wallet:2:2}" "${wallet:4:2}" "$wallet"
}

wallet_org_content_path() {
  local wallet="$1"
  local organization="$2"
  printf '%s/%s/content\n' "$(wallet_root_path "$wallet")" "$organization"
}

is_no_quorum_response() {
  local status="$1"
  local body="$2"
  [ "$status" = "503" ] &&
    [[ "$body" == *'"code":"service_unavailable"'* ]] &&
    [[ "$body" == *"no_quorum"* ]]
}

assert_accepted() {
  local status="$1"
  local body="$2"
  local label="$3"
  case "$status" in
    200|202)
      log "ACCEPTED ${label}: http=${status}"
      ;;
    *)
      fail "${label} expected 200/202, got ${status}. body=${body}"
      ;;
  esac
}

settle_http_idle() {
  local label="$1"
  if [ "$HTTP_IDLE_SETTLE_SECONDS" -le 0 ]; then
    return 0
  fi
  log "SETTLE ${label}: sleeping ${HTTP_IDLE_SETTLE_SECONDS}s for validator HTTP idle"
  sleep "$HTTP_IDLE_SETTLE_SECONDS"
}

explore_path() {
  local port="$1"
  local path="$2"
  local encoded
  local body_file
  local code
  encoded="$(encode_path "$path")"
  body_file="$(mktemp)"
  code="$(curl -s -o "$body_file" -w "%{http_code}" "http://127.0.0.1:${port}/api/explore?path=${encoded}" || echo "000")"
  printf '%s\n%s\n' "$code" "$(cat "$body_file")"
  rm -f "$body_file"
}

parent_lists_child_on_port() {
  local port="$1"
  local path="$2"
  local parent_path="${path%/*}"
  local child_name="${path##*/}"
  local result
  local code
  local body

  [ -n "$parent_path" ] || return 1
  [ "$parent_path" != "$path" ] || return 1

  result="$(explore_path "$port" "$parent_path")"
  code="$(printf '%s' "$result" | sed -n '1p')"
  body="$(printf '%s' "$result" | sed -n '2,$p')"

  [ "$code" = "200" ] || return 1
  printf '%s' "$body" | jq -e --arg child "$child_name" '(.children // []) | index($child) != null' >/dev/null 2>&1
}

sample_paths_from_file() {
  local file="$1"
  local total
  total="$(wc -l < "$file" | tr -d ' ')"
  if [ "${total:-0}" -eq 0 ]; then
    return 0
  fi
  head -n 1 "$file"
  sed -n "$(((total + 1) / 2))p" "$file"
  tail -n 1 "$file"
}

run_logged_script() {
  local description="$1"
  shift
  log "RUN ${description}"
  "$@" 2>&1 | tee -a "$RUN_LOG"
}
