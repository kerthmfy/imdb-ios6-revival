#!/usr/bin/env bash
# Deploy the IMDBCapture tweak to a jailbroken iOS 6 device over SSH.
#
#   ./deploy.sh 192.168.100.110            # root/alpine
#   ./deploy.sh 192.168.100.110 root pass
#   PREFLIGHT_ONLY=1 ./deploy.sh <ip>      # run only the safety checks
#
# iOS 6's OpenSSH only speaks the legacy KEX/host-key algorithms, so modern
# OpenSSH needs them explicitly re-enabled. scp also needs -O (legacy protocol).
#
# Safety: on a 2011-era device a hard respring at very low battery or on a
# nearly full disk is a genuine boot-loop risk, so the checks below refuse to
# install or respring and say exactly which limit was hit.

set -uo pipefail

IP="${1:?usage: ./deploy.sh <device-ip> [user] [password]}"
USER_="${2:-root}"
PW="${3:-alpine}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$DIR/.theos/obj/debug/armv7/IMDBCapture.dylib"
DEST="/Library/MobileSubstrate/DynamicLibraries"

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

# ---------------------------------------------------------------- preflight
# Refuses to continue when the device is in a state where respringing could
# leave it unable to boot. Prints every reason it found, then exits non-zero.
preflight() {
  local failed=0
  local avail_kb avail_mb df_line bat_line cur max charging pct

  # --- free space on the data partition ---
  # / is the read-only system volume and is ALWAYS nearly full on iOS 6
  # (~33 MB free is normal), so /private/var is the number that matters: it
  # holds tweaks, logs and caches, and is where a respring can wedge.
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
    ''|*[!0-9]*)
      echo "PREFLIGHT FAILED: could not parse df output: '$df_line'" >&2
      return 1
      ;;
  esac
  avail_mb=$((avail_kb / 1024))
  printf 'free space (%s): %s MB (minimum %s MB)\n' "$df_src" "$avail_mb" "$MIN_FREE_MB"
  if [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
    echo "  -> REFUSING: only ${avail_mb} MB free, need ${MIN_FREE_MB} MB." >&2
    failed=1
  fi

  # --- battery ---
  # ioreg exposes the PMU on iOS 6; if it is absent we say so instead of
  # silently passing, because the battery check is the point of this guard.
  bat_line="$(rsh 'ioreg -l 2>/dev/null | grep -iE "\"CurrentCapacity\"|\"MaxCapacity\"|\"IsCharging\"|\"BatteryInstalled\"" | head -8' | tr -d '\r')"
  if [ -z "$bat_line" ]; then
    echo "battery: UNKNOWN (ioreg unavailable on this device)"
    echo "  -> WARNING: cannot verify battery level; refusing anyway is up to you." >&2
    echo "     (set MIN_BATTERY_PCT=skip to allow a device without ioreg)" >&2
    if [ "${MIN_BATTERY_PCT}" != "skip" ]; then
      echo "  -> REFUSING: battery state unknown and MIN_BATTERY_PCT not set to 'skip'." >&2
      failed=1
    fi
  else
    cur="$(echo "$bat_line" | sed -n 's/.*"CurrentCapacity" *= *\([0-9][0-9]*\).*/\1/p' | head -1)"
    max="$(echo "$bat_line" | sed -n 's/.*"MaxCapacity" *= *\([0-9][0-9]*\).*/\1/p' | head -1)"
    charging="$(echo "$bat_line" | sed -n 's/.*"IsCharging" *= *\([A-Za-z]*\).*/\1/p' | head -1)"
    installed="$(echo "$bat_line" | sed -n 's/.*"BatteryInstalled" *= *\([A-Za-z]*\).*/\1/p' | head -1)"
    if [ "$installed" = "No" ]; then
      echo "battery: UNKNOWN (BatteryInstalled = No)"
      cur=""; max=""
    fi
    if [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
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
      echo "battery: UNKNOWN (ioreg output not understood)"
      echo "  -> WARNING: could not parse CurrentCapacity/MaxCapacity; not blocking." >&2
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
