#!/bin/bash
# Map IMDb hostnames to the shim on the iPad, or undo it.
#
#   ./enable-device.sh <device-ip> <shim-host-ip> [user] [password]
#   ./enable-device.sh --remove  <device-ip> [user] [password]
#   ./enable-device.sh --restore <device-ip> [user] [password]
#
# T2 maps both names the app might use -- app.imdb.com and imdb.com -- because
# the binary has no app.imdb.com literal (the base URL is composed at runtime)
# and we do not yet know which one it settles on. The shim's Host field records
# the answer.
#
# Safety: /etc/hosts is backed up first (timestamped plus /etc/hosts.shim.bak),
# our lines are tagged "# imdb-shim" so removal is exact, and --restore puts the
# newest backup back. No other line in the file is rewritten.
#
# Override the set with: HOSTS="app.imdb.com imdb.com sg.media-imdb.com" ./enable-device.sh ...

set -u
HOSTS="${HOSTS:-app.imdb.com imdb.com}"

MODE=add
case "${1:-}" in
  --remove)  MODE=remove;  shift ;;
  --restore) MODE=restore; shift ;;
  --add|"")  MODE=add ;;
esac

IP="${1:-}"
if [ -z "$IP" ]; then
  echo "usage: $0 [--remove|--restore] <device-ip> <shim-host-ip> [user] [password]" >&2
  exit 1
fi
shift

SHIM=""
if [ "$MODE" = "add" ]; then
  SHIM="${1:-}"
  shift || true
  if [ -z "$SHIM" ]; then
    echo "usage: $0 <device-ip> <shim-host-ip> [user] [password]" >&2
    exit 1
  fi
fi

USER_="${1:-root}"
PASS="${2:-alpine}"
OPTS=(-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
      -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=10 -o LogLevel=QUIET)
ssh_run() { sshpass -p "$PASS" ssh "${OPTS[@]}" "${USER_}@${IP}" "$@"; }

if [ "$MODE" = "restore" ]; then
  ssh_run 'B=$(ls -t /etc/hosts.shim.bak.* 2>/dev/null | head -1)
           if [ -n "$B" ]; then cp "$B" /etc/hosts && echo "restored from $B"; else echo "no backup found" >&2; fi
           grep -n imdb /etc/hosts || echo "(no imdb line)"'
  exit $?
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
CUR="$(mktemp -t hosts.cur)"
NEW="$(mktemp -t hosts.new)"
trap 'rm -f "$CUR" "$NEW"' EXIT

if ! ssh_run 'cat /etc/hosts' > "$CUR"; then
  echo "could not read /etc/hosts on $IP" >&2
  exit 1
fi
if [ ! -s "$CUR" ]; then
  echo "read an empty /etc/hosts from $IP — refusing to rewrite it" >&2
  exit 1
fi

# Drop our tagged block and any earlier untagged mapping of these same hosts
# (the manual wiring from before the marker existed). Everything else is kept.
HOST_RE="$(printf '%s\n' $HOSTS | sed 's/\./\\./g' | paste -sd'|' -)"
grep -v 'imdb-shim' "$CUR" | grep -Ev "^[0-9.]+[[:space:]]+(${HOST_RE})([[:space:]]|$)" > "$NEW" || true

if [ "$MODE" = "add" ]; then
  printf '%s %s # imdb-shim\n' "$SHIM" "$HOSTS" >> "$NEW"
  echo "pointing [$HOSTS] -> $SHIM on $IP"
else
  echo "removing imdb-shim mapping on $IP"
fi

# Back up before the write, every time; the timestamped copy is the rollback.
if ! ssh_run "cp /etc/hosts /etc/hosts.shim.bak.${STAMP} && cp /etc/hosts /etc/hosts.shim.bak"; then
  echo "backup failed — /etc/hosts was NOT modified" >&2
  exit 1
fi

if ! ssh_run 'cat > /tmp/hosts.new' < "$NEW"; then
  echo "upload failed — /etc/hosts was NOT modified (backup: /etc/hosts.shim.bak.${STAMP})" >&2
  exit 1
fi

if ! ssh_run 'cat /tmp/hosts.new > /etc/hosts && rm -f /tmp/hosts.new'; then
  echo "write failed — restoring /etc/hosts from the backup just taken" >&2
  ssh_run "cp /etc/hosts.shim.bak.${STAMP} /etc/hosts" && echo "restored"
  exit 1
fi

echo "backup: /etc/hosts.shim.bak.${STAMP}"
ssh_run 'echo "--- /etc/hosts (imdb lines) ---"; grep -n imdb /etc/hosts || echo "(no imdb line)"'
