# Enterprise-federation 3x2 topology helpers (sourced; bash 3.2).
#
# The federation topology runs two disposable 3-member clusters under one federation root
# ($FED_3X2_ROOT, default $HOME/oak-chain-federation/3x2). That root must never be, contain, or
# sit under a protected live root ($HOME/oak-chain plus OAK_PROTECTED_ROOTS, see root-guard.sh):
# the long-lived user cluster there is never touched by this topology.
#
# The root is passed to the validators inside EXTRA_JAVA_OPTS (-Doak.federation.directoryFile=…),
# which run-validator-node.sh word-splits, so it must be an absolute path without whitespace.

FED_3X2_DEFAULT_ROOT_SUFFIX="oak-chain-federation/3x2"

# Physical form of a path that may not exist yet: resolve the nearest existing ancestor.
fed_3x2_physical_path() {
  local p="$1" rest="" phys
  while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    p="${p%/*}"
  done
  [ -n "$p" ] || p="/"
  phys="$(cd "$p" 2>/dev/null && pwd -P || echo "$p")"
  [ "$phys" = "/" ] && phys=""
  echo "$phys$rest"
}

fed_3x2_strip_slashes() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  echo "$p"
}

# Protected roots, one per line: $HOME/oak-chain plus OAK_PROTECTED_ROOTS (colon separated).
fed_3x2_protected_roots() {
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

# fed_3x2_root_problem ROOT: prints why ROOT is unusable and returns 0; returns 1 when it is fine.
fed_3x2_root_problem() {
  local root="$1" form p pform IFS=$'\n'
  if [ -z "$root" ]; then echo "the federation root is empty"; return 0; fi
  case "$root" in
    /*) ;;
    *) echo "the federation root must be an absolute path: $root"; return 0 ;;
  esac
  case "$root" in
    *[[:space:]]*) echo "the federation root must not contain whitespace (it is passed in EXTRA_JAVA_OPTS): $root"; return 0 ;;
  esac
  case "/$root/" in
    */../* | */./*) echo "the federation root must not contain . or .. components: $root"; return 0 ;;
  esac
  root="$(fed_3x2_strip_slashes "$root")"
  if [ "$root" = "/" ] || [ "$root" = "$(fed_3x2_strip_slashes "$HOME")" ]; then
    echo "the federation root must be a dedicated directory, not $root"
    return 0
  fi
  for p in $(fed_3x2_protected_roots); do
    p="$(fed_3x2_strip_slashes "$p")"
    for form in "$root" "$(fed_3x2_physical_path "$root")"; do
      for pform in "$p" "$(fed_3x2_physical_path "$p")"; do
        [ -n "$pform" ] || continue
        case "$form/" in
          "$pform/"*)
            echo "the federation root $root is (or is under) the protected live root $p"
            return 0
            ;;
        esac
        case "$pform/" in
          "$form/"*)
            echo "the federation root $root contains the protected live root $p"
            return 0
            ;;
        esac
      done
    done
  done
  return 1
}

# fed_3x2_require_safe_root ROOT: refuse (return 1, reason on stderr) an unusable federation root.
fed_3x2_require_safe_root() {
  local problem
  if problem="$(fed_3x2_root_problem "$1")"; then
    echo "❌ Refusing federation 3x2: $problem" >&2
    echo "   Set FED_3X2_ROOT to a disposable absolute path outside \$HOME/oak-chain (default: \$HOME/$FED_3X2_DEFAULT_ROOT_SUFFIX)." >&2
    return 1
  fi
  return 0
}

# fed_3x2_require_cluster_root FED_ROOT CLUSTER_ROOT LABEL: the cluster root must be FED_ROOT/cluster-LABEL.
fed_3x2_require_cluster_root() {
  local fed_root expected actual
  fed_root="$(fed_3x2_strip_slashes "$1")"
  actual="$(fed_3x2_strip_slashes "$2")"
  expected="$fed_root/cluster-$3"
  if [ "$actual" != "$expected" ]; then
    echo "❌ Refusing federation 3x2: cluster $3 runtime root is $actual, expected $expected" >&2
    return 1
  fi
  fed_3x2_require_safe_root "$actual"
}

# fed_3x2_load_cluster_env CONFIG_DIR LABEL: source mock.env, ipfs.env and fed-3x2-cluster-LABEL.env
# with auto-export (as the 3x2 wrappers do), then verify that every path the lifecycle scripts will
# act on lies under the federation root. Returns 1 on any refusal; call it in a subshell.
fed_3x2_load_cluster_env() {
  local config_dir="$1" label="$2" cfg
  case "$label" in
    a | b) ;;
    *) echo "❌ Unknown federation cluster '$label' (expected a or b)" >&2; return 1 ;;
  esac
  set -a
  for cfg in "$config_dir/mock.env" "$config_dir/ipfs.env" "$config_dir/fed-3x2-cluster-$label.env"; do
    if [ ! -f "$cfg" ]; then
      set +a
      echo "❌ Missing config file: $cfg" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    if ! source "$cfg"; then
      set +a
      return 1
    fi
  done
  set +a
  fed_3x2_require_cluster_root "${FED_3X2_ROOT:-}" "${CLUSTER_RUNTIME_ROOT:-}" "$label" || return 1
  if [ "${PID_DIR:-}" != "$CLUSTER_RUNTIME_ROOT/pids" ] || [ "${LOG_DIR:-}" != "$CLUSTER_RUNTIME_ROOT/logs" ]; then
    echo "❌ Refusing federation 3x2: PID_DIR/LOG_DIR of cluster $label are not under $CLUSTER_RUNTIME_ROOT" >&2
    return 1
  fi
  return 0
}

# fed_3x2_require_jar: OAK_CONSENSUS_JAR must name an existing jar by absolute path.
fed_3x2_require_jar() {
  if [ -z "${OAK_CONSENSUS_JAR:-}" ]; then
    echo "❌ OAK_CONSENSUS_JAR is required: the absolute path of the oak-segment-consensus jar built from" >&2
    echo "   jackrabbit-oak feature/enterprise-federation (the default workspace jar is never used here)." >&2
    return 1
  fi
  case "$OAK_CONSENSUS_JAR" in
    /*) ;;
    *) echo "❌ OAK_CONSENSUS_JAR must be an absolute path: $OAK_CONSENSUS_JAR" >&2; return 1 ;;
  esac
  if [ ! -f "$OAK_CONSENSUS_JAR" ]; then
    echo "❌ OAK_CONSENSUS_JAR does not exist: $OAK_CONSENSUS_JAR" >&2
    return 1
  fi
  return 0
}

# GC overrides for federation cluster B (tests/routing/federation-3x2-gc.sh). config/fed-3x2-cluster-b.env
# appends fed_3x2_gc_java_opts "$FED_3X2_B_GC_JAVA_OPTS" to cluster B's EXTRA_JAVA_OPTS, so start-cluster.sh
# records them in the launch record; cluster A always keeps the runtime defaults. The test profile runs
# tail GC every minute, full GC every two, with Oak's backoff and size-delta guards off, and binary GC
# marking every minute with a one-minute grace and a 30 s delete delay.
FED_3X2_GC_TEST_JAVA_OPTS="-Doak.gc.tail.interval.ms=60000 -Doak.gc.full.interval.ms=120000 -Doak.gc.backoff=0 -Doak.gc.estimation.size.delta.bytes=0 -Doak.gc.binary.interval.ms=60000 -Doak.gc.binary.grace.ms=60000 -Doak.gc.binary.delete.delay.ms=30000"

# fed_3x2_gc_java_opts VALUE: print the JVM options VALUE stands for: nothing for "", the test profile
# for "test", otherwise VALUE itself. Every option must be -Doak.gc.<name>=<value> (no quotes, spaces
# or shell characters: run-validator-node.sh word-splits EXTRA_JAVA_OPTS); anything else is refused.
fed_3x2_gc_java_opts() {
  local value="$1" token out="" pattern='^-Doak\.gc\.[A-Za-z][A-Za-z.]*=[A-Za-z0-9._-]+$'
  local -a tokens=()
  if [ "$value" = "test" ]; then value="$FED_3X2_GC_TEST_JAVA_OPTS"; fi
  read -r -a tokens <<<"$value" || true
  for token in ${tokens[@]+"${tokens[@]}"}; do
    if ! [[ "$token" =~ $pattern ]]; then
      echo "❌ Refusing federation 3x2: GC option '$token' is not -Doak.gc.<name>=<value> (FED_3X2_B_GC_JAVA_OPTS)" >&2
      return 1
    fi
    out="${out:+$out }$token"
  done
  printf '%s' "$out"
}
