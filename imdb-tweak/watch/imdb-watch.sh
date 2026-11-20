#!/bin/sh
# imdb-watch.sh -- keep the revival tweak loaded across IMDb relaunches.
#
# Why this exists: MobileSubstrate injects into no new process on this device
# (its launchd bootstrap is broken; `cynject` works, but nothing loads a
# filtered dylib on its own -- see §14.2). So every relaunch of IMDb dropped the
# tweak, and "search stopped working" was indistinguishable from "the app was
# restarted". This daemon watches launchd for the app's pid and injects the
# deployed dylib once per process.
#
# It reads the dylib deploy.sh installs, so a new build is picked up on the next
# launch with no extra step. Nothing about IMDb.app is modified.
#
# Reversible: see watch.sh --remove (unload the job, delete these two files).

DYLIB=/Library/MobileSubstrate/DynamicLibraries/IMDBCapture.dylib
BUNDLE=com.imdb.imdb
LOG=/var/mobile/Library/Logs/imdbwatch.log
CYINJECT=/usr/bin/cynject

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

app_pid() {
  launchctl list 2>/dev/null | grep "UIKitApplication:$BUNDLE" | cut -f1 | head -1 | tr -d ' \r'
}

last=""
log "watcher start (watcher pid $$)"

while :; do
  pid=$(app_pid)
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac

  if [ -z "$pid" ]; then
    [ -n "$last" ] && log "app gone (was $last)"
    last=""
    sleep 1
    continue
  fi

  if [ "$pid" != "$last" ]; then
    if [ ! -s "$DYLIB" ]; then
      # Do not touch the next pid every second: one line, then wait for a relaunch.
      log "pid $pid: no dylib at $DYLIB -- not injecting"
      last="$pid"
    else
      # launchd lists the app before dyld has run its initialisers; injecting
      # that early is how you get a crash instead of a loaded tweak.
      sleep 2
      if [ "$(app_pid)" != "$pid" ]; then
        sleep 1
        continue
      fi

      attempt=0
      ok=0
      while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        if "$CYINJECT" "$pid" "$DYLIB" >>"$LOG" 2>&1; then ok=1; break; fi
        sleep 1
        [ "$(app_pid)" = "$pid" ] || break
      done

      if [ "$ok" = "1" ]; then
        log "injected pid $pid (attempt $attempt)"
      else
        log "inject pid $pid FAILED after $attempt attempt(s)"
      fi
      last="$pid"
    fi
  fi

  sleep 1
done
