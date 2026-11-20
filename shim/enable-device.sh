#!/bin/bash
# Point app.imdb.com at the shim from the iPad over SSH. Reversible with --remove.
# Usage: ./enable-device.sh <device-ip> <shim-host-ip> [user] [password]
set -e
IP="$1"; SHIM="$2"; USER="${3:-root}"; PASS="${4:-alpine}"
[ -z "$IP" ] && { echo "usage: $0 <device-ip> <shim-host-ip> [user] [password]"; exit 1; }
[ -z "$SHIM" ] && { echo "usage: $0 <device-ip> <shim-host-ip> [user] [password]"; exit 1; }

SSH="sshpass -p $PASS ssh -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o StrictHostKeyChecking=no \
 -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=QUIET $USER@$IP"

if [ "$1" = "--remove" ] || [ "$3" = "--remove" ]; then
  $SSH "cp /etc/hosts /etc/hosts.shim.bak 2>/dev/null; grep -v 'app.imdb.com' /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts && rm -f /tmp/h; echo removed; cat /etc/hosts"
  exit 0
fi

$SSH "cp /etc/hosts /etc/hosts.shim.bak 2>/dev/null; grep -v 'app.imdb.com' /etc/hosts > /tmp/h; echo '$SHIM app.imdb.com' >> /tmp/h; cat /tmp/h > /etc/hosts; rm -f /tmp/h; echo '--- /etc/hosts now ---'; cat /etc/hosts"
