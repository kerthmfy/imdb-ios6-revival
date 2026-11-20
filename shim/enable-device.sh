#!/bin/bash
# Point app.imdb.com at the shim from the iPad over SSH.
#   ./enable-device.sh <device-ip> <shim-host-ip>
#   ./enable-device.sh --remove <device-ip>
set -u
IP="$1"; shift
if [ "${IP:-}" = "--remove" ]; then MODE=remove; IP="$1";
else
  MODE=add; SHIM="${1:-}"; shift || true
  [ -z "${SHIM:-}" ] && { echo "usage: $0 <device-ip> <shim-host-ip>"; exit 1; }
fi
USER="${1:-root}"; PASS="${2:-alpine}"
OPTS=(-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
      -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=10 -o LogLevel=QUIET)
ssh_run() { sshpass -p "$PASS" ssh "${OPTS[@]}" "$USER@$IP" "$@"; }

ssh_run "cp /etc/hosts /etc/hosts.shim.bak 2>/dev/null; grep -v app.imdb.com /etc/hosts > /tmp/hosts.new || true"
if [ "$MODE" = "add" ]; then
  ssh_run "echo '$SHIM app.imdb.com' >> /tmp/hosts.new"
  echo "pointing app.imdb.com -> $SHIM on $IP"
else
  echo "removing app.imdb.com entry on $IP"
fi
ssh_run "cat /tmp/hosts.new > /etc/hosts; rm -f /tmp/hosts.new; echo '--- /etc/hosts ---'; grep imdb /etc/hosts || echo '(no imdb line)'"
