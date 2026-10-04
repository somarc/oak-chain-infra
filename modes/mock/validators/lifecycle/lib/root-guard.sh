# Runtime-root safety guard for the local mock validator cluster (sourced; bash 3.2).
#
# Consensus test charter §3: the long-lived cluster under the legacy root ($HOME/oak-chain)
# is a read-only baseline. Risk class C (signals, restarts) and D (--fresh, wipes, GC)
# actions must bind an explicit, disposable runtime root. This guard:
#   - refuses class C/D actions on a protected root unless OAK_ALLOW_LIVE_ROOT=1;
#   - refuses to sweep ports that are held by processes belonging to another root
#     (the --fresh port sweep used to kill whatever held the port).
#
# Protected roots: $HOME/oak-chain, plus any extra paths in OAK_PROTECTED_ROOTS (colon
# separated). The default can only be extended, never removed.
#
# Ownership (same rule as lifecycle/member.sh): a process belongs to ROOT when its command
# line names ROOT/validator- (every validator is launched with --store ROOT/validator-N), or
# its pid is recorded in a pid file under ROOT's PID_DIR (OPS proxy, caffeinate, watchdog;
# the shared IPFS daemon's pid file is ignored).
#
# Lives in lifecycle/lib because lifecycle owns the runtime-root contract (launch record,
# member.sh) and is self-contained; tests/ and load-tests/ source it by relative path.

oak_guard_say() { echo "$*" >&2; }

oak_guard_norm() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  echo "$p"
}

# Prints the logical and (if it exists) physical form of a path, one per line.
oak_guard_forms() {
  local p phys
  p="$(oak_guard_norm "$1")"
  echo "$p"
  phys="$(cd "$p" 2>/dev/null && pwd -P || true)"
  if [ -n "$phys" ] && [ "$phys" != "$p" ]; then echo "$phys"; fi
}

oak_guard_protected_roots() {
  local extra r
  echo "$HOME/oak-chain"
  extra="${OAK_PROTECTED_ROOTS:-}"
  while [ -n "$extra" ]; do
    r="${extra%%:*}"
    [ -n "$r" ] && echo "$r"
    if [ "$r" = "$extra" ]; then break; fi
    extra="${extra#*:}"
  done
}

# 0 if ROOT is a protected (live) runtime root.
oak_guard_is_protected_root() {
  local root="$1" a b p IFS=$'\n'
  for p in $(oak_guard_protected_roots); do
    for a in $(oak_guard_forms "$root"); do
      for b in $(oak_guard_forms "$p"); do
        [ "$a" = "$b" ] && return 0
      done
    done
  done
  return 1
}

# Refuse a class C/D action on a protected root unless OAK_ALLOW_LIVE_ROOT=1.
oak_guard_require_disposable_root() {
  local root="$1" action="$2"
  if [ -z "$root" ]; then
    oak_guard_say "❌ Refusing ${action}: no runtime root bound (set CLUSTER_RUNTIME_ROOT)."
    return 1
  fi
  oak_guard_is_protected_root "$root" || return 0
  if [ "${OAK_ALLOW_LIVE_ROOT:-}" = "1" ]; then
    oak_guard_say "⚠️  ${action} on the protected live root $root (OAK_ALLOW_LIVE_ROOT=1)."
    return 0
  fi
  oak_guard_say "❌ Refusing ${action}: $root is the protected live runtime root."
  oak_guard_say "   Charter §3.2: the long-lived cluster is a read-only baseline. Bind a disposable"
  oak_guard_say "   CLUSTER_RUNTIME_ROOT, or set OAK_ALLOW_LIVE_ROOT=1 to approve this action explicitly."
  return 1
}

# 0 if PID belongs to ROOT (command line names ROOT/validator-, or PID is in a PID_DIR pid file).
oak_guard_pid_owned() {
  local pid="$1" root="$2" pid_dir="${3:-}" cmd form f IFS=$'\n'
  [ -n "$pid" ] || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  for form in $(oak_guard_forms "$root"); do
    case "$cmd" in *"$form/validator-"*) return 0 ;; esac
  done
  if [ -n "$pid_dir" ] && [ -d "$pid_dir" ]; then
    for f in "$pid_dir"/*.pid; do
      [ -f "$f" ] || continue
      case "${f##*/}" in ipfs*) continue ;; esac  # shared IPFS daemon is never a cluster port holder
      [ "$(tr -d '[:space:]' < "$f" 2>/dev/null)" = "$pid" ] && return 0
    done
  fi
  return 1
}

# "port pid" for every TCP listener and bound UDP socket on the given ports (local side only).
oak_guard_port_holders() {
  local want=" $* "
  lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null | awk -v want="$want" 'NR > 1 {
      name = $9; sub(/->.*/, "", name)
      n = split(name, parts, ":"); port = parts[n]; sub(/[^0-9].*/, "", port)
      if (port != "" && index(want, " " port " ") > 0) print port, $2
    }' | sort -u
}

# Validator HTTP (even and odd) and Aeron (base + n*100 + 0..6) ports of one cluster.
oak_guard_cluster_ports() {
  local size="$1" http_base="$2" http_step="$3" aeron_base="$4" node=0 offset
  while [ "$node" -lt "$size" ]; do
    echo $((http_base + node * http_step))
    echo $((http_base + 1 + node * http_step))
    for offset in 0 1 2 3 4 5 6; do
      echo $((aeron_base + node * 100 + offset))
    done
    node=$((node + 1))
  done
}

# Prints "port pid command" for holders of PORTS that do not belong to ROOT; 0 if any.
oak_guard_foreign_holders() {
  local root="$1" pid_dir="$2" port pid found=1
  shift 2
  while read -r port pid; do
    [ -n "$pid" ] || continue
    oak_guard_pid_owned "$pid" "$root" "$pid_dir" && continue
    echo "$port $pid $(ps -p "$pid" -o command= 2>/dev/null | cut -c1-160)"
    found=0
  done <<EOF
$(oak_guard_port_holders "$@")
EOF
  return $found
}

# Refuse ACTION when any of PORTS is held by a process that does not belong to ROOT.
oak_guard_require_owned_ports() {
  local root="$1" pid_dir="$2" action="$3" foreign
  shift 3
  foreign="$(oak_guard_foreign_holders "$root" "$pid_dir" "$@" || true)"
  [ -z "$foreign" ] && return 0
  oak_guard_say "❌ Refusing ${action}: these ports are held by processes outside $root:"
  printf '%s\n' "$foreign" | sed 's/^/     :/' >&2
  oak_guard_say "   They probably belong to a cluster launched under another CLUSTER_RUNTIME_ROOT."
  oak_guard_say "   Stop that cluster from its own root, or bind this run to different ports."
  return 1
}

# Class D gate for --fresh: disposable root, and every cluster port free or owned by ROOT.
oak_guard_require_fresh_safe() {
  local root="$1" pid_dir="$2" size="$3" http_base="$4" http_step="$5" aeron_base="$6"
  oak_guard_require_disposable_root "$root" "--fresh" || return 1
  # shellcheck disable=SC2046
  oak_guard_require_owned_ports "$root" "$pid_dir" "--fresh" \
    $(oak_guard_cluster_ports "$size" "$http_base" "$http_step" "$aeron_base")
}

# Same gates for scripts that only know the target from the environment. ACTION names the
# class C/D work; extra args are additional ports to check (e.g. the VALIDATOR_URL port).
oak_guard_require_target_from_env() {
  local action="$1" root pid_dir
  shift
  root="${CLUSTER_RUNTIME_ROOT:-$HOME/oak-chain}"
  pid_dir="${PID_DIR:-$root/pids}"
  oak_guard_require_disposable_root "$root" "$action" || return 1
  # shellcheck disable=SC2046
  oak_guard_require_owned_ports "$root" "$pid_dir" "$action" "$@" \
    $(oak_guard_cluster_ports "${OAK_CLUSTER_SIZE:-3}" "${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}" \
      "${OAK_VALIDATOR_HTTP_PORT_STEP:-2}" "${AERON_CLUSTER_BASE_PORT:-9000}")
}

# Port number of an http(s) URL (default 80/443).
oak_guard_url_port() {
  local url="$1" hostport
  hostport="${url#*://}"
  hostport="${hostport%%/*}"
  case "$hostport" in
    *:*) echo "${hostport##*:}" ;;
    *) case "$url" in https://*) echo 443 ;; *) echo 80 ;; esac ;;
  esac
}

# SIGKILL the holders of PORTS that belong to ROOT; report and skip everything else.
oak_guard_kill_owned_ports() {
  local root="$1" pid_dir="$2" port pid
  shift 2
  while read -r port pid; do
    [ -n "$pid" ] || continue
    if oak_guard_pid_owned "$pid" "$root" "$pid_dir"; then
      echo "• Clearing port $port (pid $pid)"
      kill -9 "$pid" 2>/dev/null || true
    else
      echo "• Skipping port $port: pid $pid is not part of $root ($(ps -p "$pid" -o command= 2>/dev/null | cut -c1-100))"
    fi
  done <<EOF
$(oak_guard_port_holders "$@")
EOF
}
