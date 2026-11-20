# imdb-ios6-revival

Research + tooling for keeping the **IMDb iOS app 3.4.2** (last build for iOS 6) usable on an
**iPad 2, iOS 6.1.3**. The app installs and launches, but most of its UI is empty or errors out.

## Status

| Feature | State | Cause |
|---|---|---|
| Search | works | served by `sg.media-imdb.com/suggests/`, still live |
| Home / browse feeds | blank | `/browse/*` on `app.imdb.com`, which no longer accepts connections |
| Tap a search result | error | `/title/<id>/maindetails` on the same dead host |
| Sign in | dead | webview OAuth flow against `secure.imdb.com` (`/auth/O2/token`) |

## What the app talks to

Extracted from the app binary (`strings` + `otool -oV`), not guessed:

- Hosts: `app.imdb.com`, `api.imdbws.com`, `sg.media-imdb.com`, `secure.imdb.com`,
  `ios-app-config.media-imdb.com`, `feeds.media-imdb.com`, `m.imdb.com`
- Base template: `http://imdb.com%@` (plain HTTP)
- Detail endpoints: `/title/%@/maindetails`, `/name/%@/maindetails`, `/character/%@/maindetails`
  with `Title.Maindetails.IPhone` / `Title.Maindetails.IPad` response variants
- Home endpoints: `/browse/movies/*`, `/browse/tv/*`, `/browse/people/*`
- Lists: `/lists/watchlist`, `/lists/alllists`, `/lists/userlist`, `/title/usercomments`
- Networking: `NSURLConnection` + `UIWebView` (no third-party HTTP client)
- Per-title user state: `IMTitleUserData` -> `userIdentifier`, `userRating`, `watchlistId`

## Layout

```
imdb-tweak/     Theos tweak (armv7, iOS 6) that hooks the app's networking and logs requests
imdb-capture/   mitmproxy harness that logs an iOS 6 device's traffic from a Mac
```

## imdb-tweak

```
make                                  # needs Theos with iPhoneOS6.1.sdk
THEOS_DEVICE_IP=... make package install
./deploy.sh <device-ip> [user] [password]
./pull-log.sh <device-ip>
```

Installs to `/Library/MobileSubstrate/DynamicLibraries/` with a `Bundles = ( "com.imdb.imdb" )`
filter; writes `/var/mobile/Library/Logs/imdb-capture.log`.

The deploy script is deliberately paranoid, because this device has already been put into safe
mode once by a dylib that was left in the load path **without** its filter plist (Substrate then
injects it into every process, SpringBoard included):

- refuses to run when `/private/var` free space or battery is below threshold (`MIN_FREE_MB`,
  `MIN_BATTERY_PCT`), printing the reason;
- writes the filter plist **before** the dylib, so an interrupted copy can only leave a harmless
  filter with no dylib;
- verifies the final pair (both files non-empty, plist contains the bundle id) and **rolls the
  dylib back** if verification fails;
- re-runs the preflight right before respringing;
- resprings with `sbreload` (graceful) - never `killall -9 SpringBoard`;
- `./deploy.sh --remove <ip>` uninstalls both files and only resprings if something was removed;
- `./deploy.sh --selftest` exercises the verifier locally with four cases.

`Tweak.x` is the pure-C load marker. `Tweak.xm` is the request-logging build
(NSURLConnection / UIWebView / NSMutableURLRequest hooks). Builds are armv7 against
`iPhoneOS6.1.sdk`, MRC, Foundation-only.

**Known issue:** on this device the dylib appears in the app's loaded-image list, but its
initialiser never writes a byte, so injection is unconfirmed. Crashes seen while testing were
watchdog kills (`0x8badf00d`) caused by launching the app over SSH (`uiopen`), which also
happens with no tweak installed - they are not caused by the tweak.

## imdb-capture

`./run-capture.sh` starts mitmproxy on `:8080` with an addon that writes `traffic.jsonl`,
`traffic.log` and response bodies. Point the device's Wi-Fi HTTP proxy at the Mac and install
the CA from `http://mitm.it`. `python3 summarize.py` groups captured requests into endpoint
templates with status codes. Verified intercepting HTTPS from a device.

## Next steps

1. Confirm injection (pure-C `.x` marker build), or add an `LC_LOAD_DYLIB` to the app binary
   and re-sign with `ldid` to bypass MobileSubstrate entirely.
2. Capture the exact `/title/<id>/maindetails` request and its JSON field names.
3. Serve those paths locally and map `app.imdb.com` to it via `/etc/hosts`, backed by
   `api.graphql.imdb.com` (verified reachable, returns title/rating/plot data unauthenticated).
4. Sign-in can only become a local pseudo-account - the real OAuth flow is gone.

## Legal

No app binaries, no IMDb or Apple code, and no device secrets are stored here. The app itself
must come from your own device. IMDb data belongs to IMDb; this is a personal-compatibility
hobby project.

## shim (MVP)

`shim/server.py` is a dependency-free HTTP server that stands in for `app.imdb.com`:

- `GET /hello` -> `{ data: { time, status, api_key } }` (session bootstrap, no `exp`)
- `GET /title/<tconst>/maindetails` and `GET /title/maindetails?tconst=<tconst>` ->
  archived maindetails payload with `exp` set an hour ahead
- everything else -> JSON 404, still logged

```bash
cd shim
PORT=8080 ./run-shim.sh        # local testing, no privileges needed
PORT=80   ./run-shim.sh        # what the device needs; port 80 is privileged
./enable-device.sh <ipad-ip> <mac-ip>           # points app.imdb.com at the shim
./enable-device.sh --remove <ipad-ip>           # undo the hosts entry
```

Plain HTTP is deliberate: the app builds URLs as `http://imdb.com%@`, so no certificate is
involved. `shim/requests.jsonl` records every request, so the shim doubles as the capture the
device-side tweak never produced.

MVP limits: every title returns the archived *Fight Club* body with the requested `tconst`
substituted, so ratings/plot are wrong for other ids. Feed routes (`/browse/*`, `/chart/*`) are
not implemented yet. `/hello` returns a constant `api_key`; nothing validates it because the shim
is the server.

Both the Mac and the iPad are on DHCP here — re-check `ipconfig getifaddr en0` before wiring the
device, since the shim host address has already moved once.
