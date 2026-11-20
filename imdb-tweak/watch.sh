#!/usr/bin/env bash
# Keep the IMDb revival tweak loaded without hand-injecting after each launch.
#
#   ./watch.sh install <device-ip>   # install + start the launchd daemon
#   ./watch.sh status  <device-ip>   # is it running, and what did it inject?
#   ./watch.sh remove  <device-ip>   # stop it and delete every file it added
#
# Why this instead of a load command in IMDb.app: patching the app binary means
# editing and re-signing a store-signed bundle (and, if the binary is still
# FairPlay-encrypted, dumping it first). This daemon touches nothing in the app:
# it watches launchd for the app's pid and calls cynject, the same call we had
# been making by hand. Uninstalling is two files and one launchctl call.
#
# Uses the dylib deploy.sh installs, so rebuild+deploy is all a new build needs.

set -uo pipefail

MODE="${1:-}"
IP="${2:-}"
if [ -z "$MODE" ] || [ -z "$IP" ]; then
  echo "usage: ./watch.sh {install|status|remove} <device-ip> [user] [password]" >&2
  exit 1
fi
USER_="${3:-root}"
PW="${4:-alpine}"

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_SCRIPT="$DIR/watch/imdb-watch.sh"
SRC_PLIST="$DIR/watch/com.imdbrevival.watch.plist"
LABEL="com.imdbrevival.watch"
DEV_SCRIPT="/var/root/imdb-watch.sh"
DEV_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DEV_DYLIB="/Library/MobileSubstrate/DynamicLibraries/IMDBCapture.dylib"
DEV_LOG="/var/mobile/Library/Logs/imdbwatch.log"

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

running_expr() {
  printf 'launchctl list 2>/dev/null | grep -c "%s"' "$LABEL"
}

case "$MODE" in
  install)
    for f in "$SRC_SCRIPT" "$SRC_PLIST"; do
      [ -s "$f" ] || { echo "missing $f" >&2; exit 1; }
    done

    echo "== device =="
    rsh 'sysctl -n hw.model 2>/dev/null; sysctl -n kern.osversion 2>/dev/null' || exit 1

    echo
    echo "== dylib =="
    if ! rsh "[ -s '$DEV_DYLIB' ]"; then
      echo "REFUSING: $DEV_DYLIB is missing or empty." >&2
      echo "Run ./deploy.sh $IP first -- the watcher only injects what is deployed." >&2
      exit 2
    fi
    rsh "ls -l '$DEV_DYLIB'"

    echo
    echo "== deploy watcher =="
    # backup point for a previous copy (plist or script), so --remove never has
    # to guess what was here before
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACK="/var/root/imdb-watch-backup-${STAMP}"
    rsh "mkdir -p '$BACK'; [ -f '$DEV_PLIST' ] && cp -p '$DEV_PLIST' '$BACK/'; \
         [ -f '$DEV_SCRIPT' ] && cp -p '$DEV_SCRIPT' '$BACK/'; echo \"backup: $BACK\""

    # unload first: a loaded job keeps the old script path cached
    rsh "launchctl unload -w '$DEV_PLIST' 2>/dev/null; true"

    rcp "$SRC_SCRIPT" "${USER_}@${IP}:${DEV_SCRIPT}" || { echo "script copy failed" >&2; exit 3; }
    rcp "$SRC_PLIST"  "${USER_}@${IP}:${DEV_PLIST}"  || { echo "plist copy failed" >&2; exit 3; }
    rsh "chown root:wheel '$DEV_SCRIPT' '$DEV_PLIST'; chmod 755 '$DEV_SCRIPT'; chmod 644 '$DEV_PLIST'" || exit 4
    rsh ": > '$DEV_LOG'; true"

    echo
    echo "== load =="
    rsh "launchctl load -w '$DEV_PLIST' 2>&1; true"
    sleep 2

    if [ "$(rsh "$(running_expr)" | tr -d ' \r')" -gt 0 ]; then
      rsh "launchctl list | grep '$LABEL'"
      echo "verified: launchd has '$LABEL' loaded"
    else
      echo "VERIFY FAILED: '$LABEL' is not in launchctl list." >&2
      echo "Rolling back the daemon files (the deployed tweak is untouched)." >&2
      rsh "launchctl unload -w '$DEV_PLIST' 2>/dev/null; rm -f '$DEV_SCRIPT' '$DEV_PLIST'; true"
      exit 5
    fi

    echo
    echo "done. IMDb is injected automatically at each launch; no respring needed."
    echo "check it with: ./watch.sh status $IP"
    ;;

  status)
    echo "== launchd =="
    rsh "launchctl list | grep '$LABEL' || echo 'NOT LOADED'"
    echo
    echo "== IMDb process =="
    rsh "launchctl list | grep -i 'UIKitApplication:com.imdb.imdb' || echo 'app not running'"
    echo
    echo "== watcher log (tail) =="
    rsh "tail -12 '$DEV_LOG' 2>/dev/null || echo 'no log yet'"
    ;;

  remove)
    echo "== unload =="
    rsh "launchctl unload -w '$DEV_PLIST' 2>/dev/null; \
         rm -f '$DEV_SCRIPT' '$DEV_PLIST'; \
         echo \"remaining: \$(ls '/Library/LaunchDaemons' | grep -c '$LABEL')\""
    echo "removed. The tweak dylib and routes are still deployed;"
    echo "injection is manual again (cynject <pid> $DEV_DYLIB)."
    echo "To remove the tweak too: ./deploy.sh --remove $IP"
    ;;

  *)
    echo "usage: ./watch.sh {install|status|remove} <device-ip> [user] [password]" >&2
    exit 1
    ;;
esac
