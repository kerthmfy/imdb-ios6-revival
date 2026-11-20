#!/usr/bin/env bash
# Deploy the IMDBCapture tweak to a jailbroken iOS 6 device over SSH.
#
#   ./deploy.sh <device-ip>              # install (root/alpine)
#   ./deploy.sh <device-ip> root pass
#   ./deploy.sh --remove <device-ip>     # uninstall cleanly
#   PREFLIGHT_ONLY=1 ./deploy.sh <ip>    # run only the safety checks
#   ./deploy.sh --selftest               # test the install verifier locally
#
# iOS 6's OpenSSH only speaks the legacy KEX/host-key algorithms, so modern
# OpenSSH needs them explicitly re-enabled. scp also needs -O (legacy protocol).
#
# ---------------------------------------------------------------------------
# Safety rules learned the hard way on this device:
#
#   1. A dylib in DynamicLibraries with NO filter plist is loaded into EVERY
#      process, including SpringBoard, and puts the device in safe mode. So the
#      plist is written FIRST, and the install is verified afterwards; if the
#      pair is incomplete the dylib is rolled back automatically.
#   2. Never hard-kill SpringBoard. `killall -9 SpringBoard` on a 2011 iPad is
#      a boot-loop risk; use sbreload (graceful) and only after the preflight
#      checks pass again.
#   3. Refuse to touch a device that is low on space or battery.
#   4. A serving build must never land without the routes directory it answers
#      from. The dylib declares that dependency itself with an embedded
#      IMDB_NEEDS_ROUTES sentinel, so the rule cannot be forgotten by whoever
#      runs the script; the probe build carries no sentinel and needs no data.
# ---------------------------------------------------------------------------

set -uo pipefail

MODE=install
if [ "${1:-}" = "--selftest" ]; then MODE=selftest; shift; fi
if [ "${1:-}" = "--remove" ]; then MODE=remove; shift; fi

IP="${1:-}"
if [ "$MODE" != "selftest" ] && [ -z "$IP" ]; then
  echo "usage: ./deploy.sh [--remove|--selftest] <device-ip> [user] [password]" >&2
  exit 1
fi
USER_="${2:-root}"
PW="${3:-alpine}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$DIR/.theos/obj/debug/armv7/IMDBCapture.dylib"
DEST="/Library/MobileSubstrate/DynamicLibraries"
NAME="IMDBCapture"

MIN_FREE_MB="${MIN_FREE_MB:-250}"
MIN_BATTERY_PCT="${MIN_BATTERY_PCT:-20}"
ROUTES_DIR="${ROUTES_DIR:-/Library/IMDbRevival/routes}"
# Live data (live suggestions, live titles) needs tlsfix: the stock iOS 6 stack
# cannot handshake with sg.media-imdb.com or api.graphql.imdb.com (-9824, §17).
# The tweak serves fixtures without it, so a missing tlsfix is a degraded build,
# not a broken one -- but it is the difference between live and frozen data, and
# it fails silently at runtime. Refuse unless told otherwise.
TLSFIX_PATH="${TLSFIX_PATH:-/Library/MobileSubstrate/DynamicLibraries/tlsfix.dylib}"
ALLOW_NO_TLSFIX="${ALLOW_NO_TLSFIX:-0}"
# auto = ask the local dylib (sentinel), 1 = always require, 0 = never require.
NEEDS_ROUTES="${NEEDS_ROUTES:-auto}"

# Does this build answer from on-device fixtures? The serving build compiles in
# the string IMDB_NEEDS_ROUTES; the probe build does not, because it serves
# nothing and must be installable on a device with no data directory yet.
routes_required() {
  case "$NEEDS_ROUTES" in
    1|yes|true) return 0 ;;
    0|no|false) return 1 ;;
  esac
  [ -f "$DYLIB" ] || return 1
  grep -aq 'IMDB_NEEDS_ROUTES' "$DYLIB"
}

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

# ------------------------------------------------------------------ verifier
# The pair must be complete or the dylib gets loaded everywhere. This is the
# check that would have caught the safe-mode incident.
check_install_expr() {
  # $1 = directory. Prints a shell expression; succeeds only for a complete,
  # non-empty dylib + plist pair whose plist actually contains a filter.
  printf '[ -s "%s/%s.dylib" ] && [ -s "%s/%s.plist" ] && grep -q "Bundles" "%s/%s.plist" && grep -q "%s" "%s/%s.plist"' \
    "$1" "$NAME" "$1" "$NAME" "$1" "$NAME" "${EXPECT_BID:-com.imdb.imdb}" "$1" "$NAME"
}

# $1 = routes directory on the device. Succeeds only for an existing,
# readable, non-empty directory: a serving dylib with nothing behind it would
# install cleanly and then render empty pages, which is harder to diagnose than
# a refusal.
routes_ok_expr() {
  printf '[ -d "%s" ] && [ -r "%s" ] && [ -n "$(ls -A "%s" 2>/dev/null)" ]' \
    "$1" "$1" "$1"
}

# $1 = tlsfix dylib path on the device. Succeeds only for an existing, non-empty
# file. tlsfix is what lets the tweak reach the live hosts (§17, §18); without it
# every live route silently falls back to the fixtures.
tlsfix_ok_expr() {
  printf '[ -s "%s" ]' "$1"
}

selftest() {
  local tmp rc failures=0
  tmp="$(mktemp -d)"
  echo "selftest in $tmp"

  # case 1: complete pair -> must pass
  head -c 4096 /dev/zero > "$tmp/$NAME.dylib"
  printf '{ Filter = { Bundles = ( "com.imdb.imdb" ); }; }\n' > "$tmp/$NAME.plist"
  if sh -c "$(check_install_expr "$tmp")"; then echo "  ok: complete pair accepted"; else echo "  FAIL: complete pair rejected"; failures=1; fi

  # case 2: dylib with no plist -> must fail (this is the safe-mode bug)
  rm -f "$tmp/$NAME.plist"
  if sh -c "$(check_install_expr "$tmp")" 2>/dev/null; then echo "  FAIL: filterless dylib accepted"; failures=1; else echo "  ok: filterless dylib rejected"; fi

  # case 3: empty plist -> must fail
  : > "$tmp/$NAME.plist"
  if sh -c "$(check_install_expr "$tmp")" 2>/dev/null; then echo "  FAIL: empty plist accepted"; failures=1; else echo "  ok: empty plist rejected"; fi

  # case 4: plist without the bundle id -> must fail
  printf '{ Filter = { Bundles = ( "com.example.other" ); }; }\n' > "$tmp/$NAME.plist"
  if sh -c "$(check_install_expr "$tmp")" 2>/dev/null; then echo "  FAIL: wrong-bundle plist accepted"; failures=1; else echo "  ok: wrong-bundle plist rejected"; fi

  # case 5: routes directory missing -> must fail
  if sh -c "$(routes_ok_expr "$tmp/routes-missing")" 2>/dev/null; then
    echo "  FAIL: missing routes dir accepted"; failures=1
  else echo "  ok: missing routes dir rejected"; fi

  # case 6: routes directory present but empty -> must fail
  mkdir -p "$tmp/routes-empty"
  if sh -c "$(routes_ok_expr "$tmp/routes-empty")" 2>/dev/null; then
    echo "  FAIL: empty routes dir accepted"; failures=1
  else echo "  ok: empty routes dir rejected"; fi

  # case 7: routes directory with a fixture -> must pass
  mkdir -p "$tmp/routes-ok"
  printf '{}\n' > "$tmp/routes-ok/hello.json"
  if sh -c "$(routes_ok_expr "$tmp/routes-ok")"; then
    echo "  ok: populated routes dir accepted"
  else echo "  FAIL: populated routes dir rejected"; failures=1; fi

  # case 8: tlsfix present -> must pass
  head -c 1024 /dev/zero > "$tmp/tlsfix.dylib"
  if sh -c "$(tlsfix_ok_expr "$tmp/tlsfix.dylib")"; then
    echo "  ok: present tlsfix accepted"
  else echo "  FAIL: present tlsfix rejected"; failures=1; fi

  # case 9: tlsfix missing -> must fail (the silent-fixtures bug)
  if sh -c "$(tlsfix_ok_expr "$tmp/tlsfix-absent.dylib")" 2>/dev/null; then
    echo "  FAIL: missing tlsfix accepted"; failures=1
  else echo "  ok: missing tlsfix rejected"; fi

  rm -rf "$tmp"
  [ "$failures" -eq 0 ] && { echo "selftest PASSED"; return 0; } || { echo "selftest FAILED" >&2; return 1; }
}

[ "$MODE" = "selftest" ] && { selftest; exit $?; }

# ---------------------------------------------------------------- preflight
preflight() {
  local failed=0
  local avail_kb avail_mb df_src df_line bat_line cur max charging installed pct

  # / is the read-only system volume and is ALWAYS nearly full on iOS 6
  # (~33 MB free is normal), so /private/var is the number that matters.
  df_src="/private/var"
  df_line="$(rsh "df -k $df_src 2>/dev/null | tail -1" | tr -d '\r')"
  if [ -z "$df_line" ]; then
    df_src="/"
    df_line="$(rsh 'df -k / 2>/dev/null | tail -1' | tr -d '\r')"
  fi
  if [ -z "$df_line" ]; then
    echo "PREFLIGHT FAILED: could not read free space over SSH." >&2
    return 1
  fi
  avail_kb="$(echo "$df_line" | tr -s ' ' | cut -d' ' -f4)"
  case "$avail_kb" in
    ''|*[!0-9]*) echo "PREFLIGHT FAILED: could not parse df output: '$df_line'" >&2; return 1 ;;
  esac
  avail_mb=$((avail_kb / 1024))
  printf 'free space (%s): %s MB (minimum %s MB)\n' "$df_src" "$avail_mb" "$MIN_FREE_MB"
  if [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
    echo "  -> REFUSING: only ${avail_mb} MB free, need ${MIN_FREE_MB} MB." >&2
    failed=1
  fi

  bat_line="$(rsh 'ioreg -l 2>/dev/null | grep -iE "\"CurrentCapacity\"|\"MaxCapacity\"|\"IsCharging\"|\"BatteryInstalled\"" | head -8' | tr -d '\r')"
  if [ -z "$bat_line" ]; then
    # This iPad has no ioreg binary at all, so a low battery can never be
    # reported to us. Refusing on unreadable state would block every install on
    # the one device we target, so unknown is a warning; low stays a refusal.
    # BATTERY_STRICT=1 restores refusing when the state cannot be read.
    echo "battery: UNKNOWN (no ioreg on this device)"
    if [ "${BATTERY_STRICT:-0}" = "1" ]; then
      echo "  -> REFUSING: battery state unknown and BATTERY_STRICT=1." >&2
      failed=1
    else
      echo "  -> continuing without a battery reading; plug the iPad in if it is not already."
    fi
  else
    cur="$(echo "$bat_line" | sed -n 's/.*"CurrentCapacity" *= *\([0-9][0-9]*\).*/\1/p' | head -1)"
    max="$(echo "$bat_line" | sed -n 's/.*"MaxCapacity" *= *\([0-9][0-9]*\).*/\1/p' | head -1)"
    charging="$(echo "$bat_line" | sed -n 's/.*"IsCharging" *= *\([A-Za-z]*\).*/\1/p' | head -1)"
    installed="$(echo "$bat_line" | sed -n 's/.*"BatteryInstalled" *= *\([A-Za-z]*\).*/\1/p' | head -1)"
    if [ "$installed" = "No" ]; then
      echo "battery: UNKNOWN (BatteryInstalled = No)"
    elif [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
      pct=$((cur * 100 / max))
      printf 'battery: %s%% (%s/%s)%s\n' "$pct" "$cur" "$max" "${charging:+, charging=$charging}"
      if [ "$pct" -lt "$MIN_BATTERY_PCT" ]; then
        if [ "$charging" = "Yes" ]; then
          echo "  -> WARNING: battery ${pct}% but charging; continuing." >&2
        else
          echo "  -> REFUSING: battery ${pct}% is below ${MIN_BATTERY_PCT}% and not charging." >&2
          echo "     Plug it in until it is above ${MIN_BATTERY_PCT}%, then rerun." >&2
          failed=1
        fi
      fi
    else
      echo "battery: UNKNOWN (ioreg output not understood) — not blocking"
    fi
  fi

  if routes_required; then
    echo "routes: required by this build -> $ROUTES_DIR"
    if rsh "$(routes_ok_expr "$ROUTES_DIR")"; then
      echo "  route entries: $(rsh "ls -A '$ROUTES_DIR' | wc -l" | tr -d ' \r')"
    else
      echo "  -> REFUSING: $ROUTES_DIR is missing, unreadable or empty on the device." >&2
      echo "     This dylib answers from those fixtures; installing it without them" >&2
      echo "     produces blank pages that look like a broken tweak. Copy the routes" >&2
      echo "     first, or set NEEDS_ROUTES=0 if you know it can run without them." >&2
      failed=1
    fi
  else
    echo "routes: not required (probe build serves nothing)"
  fi

  echo "tlsfix: $TLSFIX_PATH (required for live data)"
  if rsh "$(tlsfix_ok_expr "$TLSFIX_PATH")"; then
    echo "  found: $(rsh "ls -l '$TLSFIX_PATH' | tr -s ' ' | cut -d' ' -f5,9" | tr -d '\r') bytes"
  elif [ "$ALLOW_NO_TLSFIX" = "1" ]; then
    echo "  -> WARNING: missing, ALLOW_NO_TLSFIX=1. Search and titles will serve fixtures only." >&2
  else
    echo "  -> REFUSING: tlsfix is missing. Without it the tweak cannot handshake with" >&2
    echo "     sg.media-imdb.com or api.graphql.imdb.com (-9824) and every live route" >&2
    echo "     falls back to the fixtures, which looks like 'live data is broken'." >&2
    echo "     Install com.skyglow.tlsfix, or set ALLOW_NO_TLSFIX=1 for a fixtures-only install." >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo >&2
    echo "REFUSED: nothing was installed and SpringBoard was not touched." >&2
    echo "Override thresholds if you are sure: MIN_FREE_MB=50 MIN_BATTERY_PCT=5 ./deploy.sh ..." >&2
    return 1
  fi
  echo "preflight OK"
  return 0
}

# ---------------------------------------------------------------- respring
respring() {
  if rsh 'command -v sbreload >/dev/null 2>&1'; then
    echo "using sbreload (graceful)"
    rsh 'sbreload' || echo "sbreload returned non-zero" >&2
  else
    echo "sbreload unavailable, sending SIGHUP (not SIGKILL)"
    rsh 'killall -HUP SpringBoard 2>/dev/null; true'
  fi
}

# ---------------------------------------------------------------- uninstall
uninstall() {
  local stamp out moved
  stamp="$(date +%Y%m%d-%H%M%S)"
  echo "== uninstalling =="
  out="$(rsh "mkdir -p '/tmp/imdbcap-uninstalled-$stamp'; n=0;
       for f in '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist'; do
         if [ -e \"\$f\" ]; then mv \"\$f\" '/tmp/imdbcap-uninstalled-$stamp/' && echo \"moved \$f\" && n=\$((n+1)); fi;
       done;
       echo \"moved_count=\$n\";
       echo \"remaining=\$(ls '${DEST}' | grep -ci ${NAME})\"")"
  printf '%s\n' "$out"
  moved="$(printf '%s' "$out" | sed -n 's/^moved_count=\([0-9]*\).*/\1/p' | head -1)"
  if [ "${moved:-0}" -eq 0 ]; then
    echo "nothing installed for $NAME — not respringing."
    return 0
  fi
  echo
  echo "== respring =="
  respring
  echo "removed. Backup kept in /tmp/imdbcap-uninstalled-$stamp"
}

if [ "$MODE" = "remove" ]; then
  echo "== device =="
  rsh 'sysctl -n hw.model 2>/dev/null; sysctl -n kern.osversion 2>/dev/null' || exit 1
  uninstall
  exit 0
fi

# ---------------------------------------------------------------- install
[ -f "$DYLIB" ] || { echo "no dylib — run make first" >&2; exit 1; }

# iOS 6 will not load an injected dylib that has no code signature: it SIGILLs
# the host process (dyld traps it). Theos printed "Signing" but produced a
# binary with no LC_CODE_SIGNATURE, so this is checked, not assumed.
has_signature() { otool -l "$1" 2>/dev/null | grep -q LC_CODE_SIGNATURE; }
if ! has_signature "$DYLIB"; then
  echo "dylib is unsigned — signing with ldid"
  ldid -S "$DYLIB" || { echo "ldid failed; refusing to install an unsigned dylib" >&2; exit 8; }
fi
if ! has_signature "$DYLIB"; then
  echo "REFUSING: $DYLIB still has no LC_CODE_SIGNATURE — it would SIGILL on load." >&2
  echo "Install ldid (e.g. brew install ldid) and rebuild." >&2
  exit 8
fi
echo "code signature: present"

echo "== device =="
rsh 'sysctl -n hw.model 2>/dev/null; sysctl -n kern.osversion 2>/dev/null; uname -m' || exit 1

echo
echo "== preflight =="
preflight || exit 6

if [ "${PREFLIGHT_ONLY:-0}" = "1" ]; then
  echo "PREFLIGHT_ONLY set — stopping before install."
  exit 0
fi

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

# Rollback point. Nothing is overwritten without a copy of what was there.
STAMP="$(date +%Y%m%d-%H%M%S)"
BACK="/tmp/imdbcap-backup-${STAMP}"

restore_backup() {
  # $f must expand on the device, so the remote side gets double quotes.
  rsh "for f in '${NAME}.dylib' '${NAME}.plist'; do
         if [ -f \"$BACK/\$f\" ]; then cp -p \"$BACK/\$f\" \"${DEST}/\$f\";
         else rm -f \"${DEST}/\$f\"; fi;
       done;
       echo \"restored ${DEST} from $BACK\""
}

echo
echo "== backup (rollback point) =="
rsh "mkdir -p '$BACK'; n=0;
     for f in '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist'; do
       if [ -e \"\$f\" ]; then cp -p \"\$f\" '$BACK/' && n=\$((n+1)); fi;
     done;
     echo \"backed_up=\$n dir=$BACK\"" || { echo "backup failed — refusing to write" >&2; exit 5; }

echo
echo "== installing (filter plist first, dylib second) =="
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

# plist before dylib: a dropped connection can then only leave a filter
# pointing at a missing dylib (harmless), never a dylib with no filter.
rcp "$TMPPLIST" "${USER_}@${IP}:${DEST}/${NAME}.plist" || { echo "plist copy failed — nothing installed" >&2; rm -f "$TMPPLIST"; exit 3; }
rcp "$DYLIB"    "${USER_}@${IP}:${DEST}/${NAME}.dylib" || { echo "dylib copy failed — restoring from backup" >&2; restore_backup; rm -f "$TMPPLIST"; exit 3; }
rm -f "$TMPPLIST"

rsh "chown root:wheel '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist' 2>/dev/null; \
     chmod 755 '${DEST}/${NAME}.dylib'; \
     chmod 644 '${DEST}/${NAME}.plist'; \
     rm -f /var/mobile/Library/Logs/imdb-capture.log /tmp/imdb-probe.jsonl; \
     rm -f '$APP/Documents/imdb-probe.jsonl'" || exit 4

echo
echo "== verifying install =="
EXPECT_BID="$BID"
if rsh "$(check_install_expr "$DEST")"; then
  rsh "ls -l '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist'"
  echo "verified: dylib + filter plist both present and non-empty"
else
  echo "VERIFY FAILED: the dylib/filter pair is incomplete — rolling back." >&2
  echo "  A dylib without its filter loads into every process and causes safe mode." >&2
  restore_backup
  rsh "echo \"remaining: \$(ls '${DEST}' | grep -ci ${NAME})\""
  exit 7
fi

echo
echo "== preflight again before respring =="
preflight || { echo "state changed since install; installed but NOT respringing." >&2; exit 6; }

echo
echo "== respring =="
respring
echo "backup kept at $BACK (rollback: cp -p back into $DEST)"
echo "probe installed. Launch IMDb from the home screen, search a title, tap it,"
echo "then run ./pull-log.sh $IP to fetch the request log."
echo "To undo: ./deploy.sh --remove $IP"
