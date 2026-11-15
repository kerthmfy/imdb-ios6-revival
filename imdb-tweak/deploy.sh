#!/usr/bin/env bash
# Deploy the IMDBCapture tweak to a jailbroken iOS 6 device over SSH.
#
#   ./deploy.sh 192.168.100.110            # root/alpine
#   ./deploy.sh 192.168.100.110 root pass
#
# iOS 6's OpenSSH only speaks the legacy KEX/host-key algorithms, so modern
# OpenSSH needs them explicitly re-enabled. scp also needs -O (legacy protocol).

set -uo pipefail

IP="${1:?usage: ./deploy.sh <device-ip> [user] [password]}"
USER_="${2:-root}"
PW="${3:-alpine}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$DIR/.theos/obj/debug/armv7/IMDBCapture.dylib"
DEST="/Library/MobileSubstrate/DynamicLibraries"

SSH_OPTS=(
  -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
  -o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedKeyTypes=+ssh-rsa
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=QUIET
)

rsh() { sshpass -p "$PW" ssh "${SSH_OPTS[@]}" "${USER_}@${IP}" "$@"; }
rcp() { sshpass -p "$PW" scp -O "${SSH_OPTS[@]}" "$@"; }

[ -f "$DYLIB" ] || { echo "no dylib — run make first" >&2; exit 1; }

echo "== device =="
rsh 'sysctl -n hw.model 2>/dev/null; sysctl -n kern.osversion 2>/dev/null; uname -m' || exit 1

echo
echo "== IMDb app =="
APP="$(rsh 'ls -d /var/mobile/Applications/*/IMDb.app 2>/dev/null | head -1' | tr -d '\r')"
if [ -z "$APP" ]; then
  echo "IMDb.app not found in /var/mobile/Applications — aborting install."
  exit 2
fi
echo "path: $APP"

BID="$(rsh "strings '$APP/Info.plist' 2>/dev/null | grep -Eo 'com\.[A-Za-z0-9.]*imdb[A-Za-z0-9.]*' | head -1" | tr -d '\r')"
[ -z "$BID" ] && BID="com.imdb.imdb"
VER="$(rsh "strings '$APP/Info.plist' 2>/dev/null | grep -Eo '^[0-9]+\\.[0-9]+(\\.[0-9]+)?\$' | head -1" | tr -d '\r')"
echo "bundle id: $BID   version: ${VER:-unknown}"

echo
echo "== MobileSubstrate =="
rsh 'ls -d /Library/MobileSubstrate >/dev/null 2>&1 && echo present || echo MISSING'

echo
echo "== installing =="
TMPPLIST="$(mktemp -t imdbcap)"
cat > "$TMPPLIST" <<PLIST
{
    Filter = {
        Bundles = (
            "$BID"
        );
    };
}
PLIST

rcp "$DYLIB" "${USER_}@${IP}:${DEST}/IMDBCapture.dylib" || exit 3
rcp "$TMPPLIST" "${USER_}@${IP}:${DEST}/IMDBCapture.plist" || exit 3
rm -f "$TMPPLIST"

rsh "chown root:wheel '${DEST}/IMDBCapture.dylib' '${DEST}/IMDBCapture.plist'; \
     chmod 755 '${DEST}/IMDBCapture.dylib'; \
     chmod 644 '${DEST}/IMDBCapture.plist'; \
     rm -f /var/mobile/Library/Logs/imdb-capture.log; \
     ls -l '${DEST}/IMDBCapture.dylib' '${DEST}/IMDBCapture.plist'" || exit 4

echo
echo "== respring =="
rsh 'killall -9 SpringBoard 2>/dev/null; true'
echo "installed. Launch IMDb, search a title, tap it, then run ./pull-log.sh $IP"
