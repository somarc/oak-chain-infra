# Local IPFS gateway port for the mock validator clusters (sourced; bash 3.2).
#
# Default: 127.0.0.1:5080. It sits next to the other Kubo ports (swarm 4001, API 5001) and
# outside every range the clusters bind on one host:
#   validator HTTP + standby  8090-8099, 8190-8199, 8290-8299 (and upward by cluster)
#   OPS proxies               8787-8789
#   Aeron                     9000-10006
# The old default, 8099, is validator-4's standby port (HTTP base 8090 + 1 + 4*2) in every
# 5-member cluster, so a 5-member topology could not start while the daemon served it.
# Kubo's own default, 8080, is avoided too: Docker and dev servers commonly hold it.
#
# An existing ~/.ipfs repo keeps its Addresses.Gateway until reconfigured; see
# TROUBLESHOOTING.md ("IPFS gateway on a validator port").

OAK_IPFS_GATEWAY_DEFAULT_BASE="http://127.0.0.1:5080/ipfs/"
# Every launch record written before the gateway was recorded comes from a cluster launched
# with this value (config/mock.env, config/ipfs.env and run-validator-node.sh all pinned it).
OAK_LEGACY_IPFS_GATEWAY_BASE="http://127.0.0.1:8099/ipfs/"

# Kubo multiaddr for a loopback http gateway base URL; prints nothing for any other host.
oak_ipfs_gateway_multiaddr() {
  local hostport="${1#*://}" port=80
  hostport="${hostport%%/*}"
  case "$hostport" in *:*) port="${hostport##*:}" ;; esac
  case "${hostport%:*}" in
    127.0.0.1 | localhost) echo "/ip4/127.0.0.1/tcp/$port" ;;
  esac
}

# TCP ports in the Value of a Kubo `config Addresses.Gateway` API response, one per line.
# The value is a multiaddr string or a list of them.
oak_ipfs_gateway_ports_from_config() {
  printf '%s' "$1" | grep -oE '/tcp/[0-9]+' | sed 's#/tcp/##' | sort -u
}

# The running daemon's gateway ports, read from its API (read-only). Empty when unknown.
oak_ipfs_daemon_gateway_ports() {
  local api="${1%/}" json
  json="$(curl -s --max-time 3 -X POST "$api/api/v0/config?arg=Addresses.Gateway" 2>/dev/null || true)"
  oak_ipfs_gateway_ports_from_config "$json"
}

# The command an operator runs (cluster and daemon stopped) to move an existing repo's gateway.
oak_ipfs_gateway_fix_hint() {
  local multiaddr
  multiaddr="$(oak_ipfs_gateway_multiaddr "${1:-$OAK_IPFS_GATEWAY_DEFAULT_BASE}")"
  echo "ipfs config Addresses.Gateway ${multiaddr:-/ip4/127.0.0.1/tcp/5080}"
}
