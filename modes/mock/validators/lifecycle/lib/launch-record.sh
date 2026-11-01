# Launch record of the local mock validator cluster (sourced; bash 3.2).
#
# start-cluster.sh writes $PID_DIR/cluster-launch.env; lifecycle/member.sh and the mock console
# (src/mock-console.mjs parseLaunchRecord) read it back to relaunch a member exactly as its
# peers were launched.
#
# Format: one KEY=VALUE per line; '#' lines are comments. VALUE is everything after the first
# '=', verbatim: no quoting, no escaping, and the file is never sourced. Both readers split on
# the first '=' only, so values with spaces, ';', '=' and ':' (the EXTRA_JAVA_OPTS sharding
# routes, e.g. -Doak.sharding.remote.routes=56-aa=http://127.0.0.1:8190;ab-ff=...) round-trip
# unchanged. A value cannot hold a line break; the writer refuses one rather than corrupt the
# record. (The console trims surrounding whitespace from each line; member.sh does not.)

# oak_launch_record_write FILE KEY=VALUE... : atomically replace FILE with the given pairs.
oak_launch_record_write() {
  local file="$1" pair nl=$'\n' cr=$'\r'
  shift
  for pair in "$@"; do
    case "$pair" in
      *"$nl"* | *"$cr"*)
        echo "❌ Launch record: ${pair%%=*} contains a line break; refusing to write $file" >&2
        return 1
        ;;
    esac
  done
  {
    echo "# Written by start-cluster.sh at launch; read by member.sh and the mock console. Do not edit."
    printf '%s\n' "$@"
  } > "$file.tmp" || return 1
  mv "$file.tmp" "$file"
}

# oak_launch_record_get FILE KEY : print KEY's value; return 1 when FILE or KEY is absent.
oak_launch_record_get() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) echo "${line#*=}"; return 0 ;; esac
  done < "$file"
  return 1
}
