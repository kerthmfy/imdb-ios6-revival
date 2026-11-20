#!/usr/bin/env bash
# Pull the capture logs off the iPad, out of the app's own container.
#
#   ./pull-log.sh 192.168.100.130 [root]
#
# T1: the IMDb.app container is discovered on the device (the bundle lives at
# <container>/IMDb.app, so the log is at <container>/Documents/imdb-capture.log)
# instead of assuming a system-wide path the App Store sandbox may deny. The
# probe build's JSON lines and the /tmp fallbacks are collected too, so this one
# command works for both builds.
#
# Writes ./imdb-capture.log next to this script and prints a summary.
#
# Uses the legacy algorithms iOS 6's OpenSSH needs; modern OpenSSH refuses those
# by default, which is the usual "no matching key exchange method" error.

set -uo pipefail
IP="${1:?usage: ./pull-log.sh <ipad-ip> [user] [password]}"
USER_="${2:-root}"
PW="${3:-alpine}"
OUT="$(cd "$(dirname "$0")" && pwd)/imdb-capture.log"

# sshpass is required for a non-interactive run; without it ssh prompts and the
# capture silently comes back empty (which reads as "the tweak never ran").
SSHPASS=()
if command -v sshpass >/dev/null 2>&1; then SSHPASS=(sshpass -p "$PW"); fi

"${SSHPASS[@]}" ssh -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedKeyTypes=+ssh-rsa \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "${USER_}@${IP}" '
      show() {
        if [ -s "$1" ]; then echo "## $1"; cat "$1"; fi
      }
      APP=$(ls -d /var/mobile/Applications/*/IMDb.app 2>/dev/null | head -1)
      if [ -n "$APP" ]; then
        CT=$(dirname "$APP")
        echo "## container $CT"
        show "$CT/Documents/imdb-capture.log"
        show "$CT/Documents/imdb-probe.jsonl"
      else
        echo "## no IMDb.app found under /var/mobile/Applications"
      fi
      # Fallbacks: /tmp is writable from a sandboxed app; the system Logs path
      # only exists for builds from before the container-path fix.
      show /tmp/imdb-capture.log
      show /tmp/imdb-probe.jsonl
      show /var/mobile/Library/Logs/imdb-capture.log
      true
    ' > "$OUT"

echo "saved $(wc -l < "$OUT" | tr -d ' ') lines to $OUT"

if [ ! -s "$OUT" ]; then
  echo
  echo "empty output — either the tweak never ran in the app process (check the"
  echo "filter plist's bundle id) or the device could not be read at all."
  exit 0
fi

echo
echo "sections found:"
grep '^## ' "$OUT" || true

echo
echo "probe lines by source (urlprotocol = NSURLProtocol saw it):"
grep -o '"src":"[^"]*"' "$OUT" | sed 's/^"src":"//; s/"$//' | sort | uniq -c | sort -rn || true

echo
echo "requests:"
grep -o '"url":"[^"]*"' "$OUT" | sed 's/^"url":"//; s/"$//' | sort | uniq -c | sort -rn | head -40 || true
