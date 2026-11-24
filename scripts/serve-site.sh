#!/bin/bash
# Serves site/ to your other Tailscale devices for testing. Bound to this Mac's Tailscale address only,
# so it isn't reachable from the local network. Ctrl-C to stop. Usage: scripts/serve-site.sh [port]
set -euo pipefail
cd "$(dirname "$0")/../site"
ip=$(tailscale ip -4)
port=${1:-8765}
echo "Hush site: http://$ip:$port  (or http://$(tailscale status --self --peers=false | awk '{print $2}'):$port with MagicDNS)"
exec python3 -m http.server "$port" --bind "$ip"
