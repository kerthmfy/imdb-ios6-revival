#!/usr/bin/env bash
# Pull the capture log off the iPad.
#
#   ./pull-log.sh 192.168.100.xx [root]
#
# Uses the legacy algorithms iOS 6's OpenSSH needs; modern OpenSSH refuses
# those by default, which is the usual "no matching key exchange method" error.

set -euo pipefail
IP="${1:?usage: ./pull-log.sh <ipad-ip> [user]}"
USER_="${2:-root}"
OUT="$(dirname "$0")/imdb-capture.log"

ssh -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedKeyTypes=+ssh-rsa \
    -o StrictHostKeyChecking=no \
    "${USER_}@${IP}" "cat /var/mobile/Library/Logs/imdb-capture.log" > "$OUT"

echo "saved $(wc -l < "$OUT" | tr -d ' ') lines to $OUT"
echo
echo "endpoints requested:"
grep -o 'REQ  [A-Z]* .*' "$OUT" | sed 's/^REQ  //' | sort | uniq -c | sort -rn | head -40
