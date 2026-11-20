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
    echo "battery: UNKNOWN (ioreg unavailable)"
    if [ "${MIN_BATTERY_PCT}" != "skip" ]; then
      echo "  -> REFUSING: battery state unknown (set MIN_BATTERY_PCT=skip to override)." >&2
      failed=1
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
rcp "$DYLIB"    "${USER_}@${IP}:${DEST}/${NAME}.dylib" || { echo "dylib copy failed — rolling back plist" >&2; rsh "rm -f '${DEST}/${NAME}.plist'"; rm -f "$TMPPLIST"; exit 3; }
rm -f "$TMPPLIST"

rsh "chown root:wheel '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist' 2>/dev/null; \
     chmod 755 '${DEST}/${NAME}.dylib'; \
     chmod 644 '${DEST}/${NAME}.plist'; \
     rm -f /var/mobile/Library/Logs/imdb-capture.log" || exit 4

echo
echo "== verifying install =="
EXPECT_BID="$BID"
if rsh "$(check_install_expr "$DEST")"; then
  rsh "ls -l '${DEST}/${NAME}.dylib' '${DEST}/${NAME}.plist'"
  echo "verified: dylib + filter plist both present and non-empty"
else
  echo "VERIFY FAILED: the dylib/filter pair is incomplete — rolling back." >&2
  echo "  A dylib without its filter loads into every process and causes safe mode." >&2
  rsh "mv '${DEST}/${NAME}.dylib' '/tmp/${NAME}.dylib.rollback' 2>/dev/null; rm -f '${DEST}/${NAME}.plist'; \
       echo \"rolled back; remaining: \$(ls '${DEST}' | grep -ci ${NAME})\""
  exit 7
fi

echo
echo "== preflight again before respring =="
preflight || { echo "state changed since install; installed but NOT respringing." >&2; exit 6; }

echo
echo "== respring =="
respring
echo "installed. Launch IMDb, search a title, tap it, then run ./pull-log.sh $IP"
echo "To undo: ./deploy.sh --remove $IP"
