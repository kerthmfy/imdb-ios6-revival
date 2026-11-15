#!/usr/bin/env bash
# Start a MITM proxy for capturing IMDb (iOS 6, iPad 2) traffic.
#
#   ./run-capture.sh              # 8080
#   PORT=9090 ./run-capture.sh
#
# Then on the iPad: Settings > Wi-Fi > (i) next to your network >
# HTTP Proxy > Manual > Server: <this Mac's IP>  Port: <PORT>
# Open Safari on the iPad and go to http://mitm.it, tap "Apple", install.
# iOS 6 trusts the cert as soon as the profile is installed.

set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8080}"
CONFDIR="$PWD/.mitm"
mkdir -p "$CONFDIR"

if ! command -v mitmdump >/dev/null 2>&1; then
  echo "mitmdump not found. Install it with: brew install mitmproxy" >&2
  exit 1
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [ -z "$LAN_IP" ]; then
  LAN_IP="$(ipconfig getifaddr en1 2>/dev/null || true)"
fi
[ -z "$LAN_IP" ] && LAN_IP="<this Mac's LAN IP>"

echo "──────────────────────────────────────────────────────────"
echo " IMDb capture proxy"
echo "   proxy for the iPad : ${LAN_IP}:${PORT}"
echo "   CA install page    : http://mitm.it  (open on the iPad)"
echo "   logs               : traffic.log / traffic.jsonl / bodies/"
echo ""
echo " iPad: Settings > Wi-Fi > (i) > HTTP Proxy > Manual"
echo "       Server ${LAN_IP}   Port ${PORT}   (auth off)"
echo "──────────────────────────────────────────────────────────"
echo

exec mitmdump \
  --listen-port "$PORT" \
  --set confdir="$CONFDIR" \
  --set connection_strategy=lazy \
  --set flow_detail=0 \
  -s capture.py
