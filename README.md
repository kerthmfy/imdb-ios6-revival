# imdb-ios6-revival

Research + tooling for keeping the **IMDb iOS app 3.4.2** (last build for iOS 6) usable on **iOS 6.1.3**. wip.

## Status

| Feature | State | Cause |
|---|---|---|
| Search | works | served by `sg.media-imdb.com/suggests/`, still live |
| Home / browse feeds | blank | `/browse/*` on `app.imdb.com`, which no longer accepts connections |
| Tap a search result | error | `/title/<id>/maindetails` on the same dead host |
| Sign in | dead | webview OAuth flow against `secure.imdb.com` (`/auth/O2/token`) |

## What the app talks to

Extracted from the app binary (`strings` + `otool -oV`), not guessed:

- Hosts: `app.imdb.com`, `api.imdbws.com` (home-page template, see below), `sg.media-imdb.com`, `secure.imdb.com`,
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
./watch.sh install <device-ip>        # keep the tweak loaded across relaunches
./watch.sh status <device-ip>
./pull-log.sh <device-ip>
```

Installs to `/Library/MobileSubstrate/DynamicLibraries/` with a `Bundles = ( "com.imdb.imdb" )`
filter. The current build is a **serving build**: it registers an `NSURLProtocol` for
`app.imdb.com` (and, for now, `sg.media-imdb.com/suggests/*`) inside the app process, answers those
from fixtures in `/Library/IMDbRevival/routes`, and hands every other host back to the system
loader untouched. Every request is logged as JSON lines to `$HOME/Documents/imdb-probe.jsonl` and
`/tmp/imdb-probe.jsonl`; `./pull-log.sh <ip>` collects them. An earlier build served nothing and
failed every IMDb request with `NSURLErrorCannotConnectToHost`, which was useful for proving the
interception layer but stopped the app at its first call, so the rest of a page's request chain was
never made.

Because interception happens above TLS, this path needs no certificate, no hosts entry and no
listening port on the Mac. Lines tagged `src=urlprotocol` were seen by the protocol;
`src=NSURLConnection:*` lines are the coverage cross-check — Foundation-created requests that
the protocol registry perhaps did not see.

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
- `./deploy.sh --selftest` exercises the verifier locally with seven cases;
- refuses a serving build whose `/Library/IMDbRevival/routes` directory is missing, unreadable
  or empty. The dependency is declared by the build itself (an embedded `IMDB_NEEDS_ROUTES`
  sentinel), not by a flag the operator can forget; the probe build carries no sentinel and
  installs without any data directory.

### Keeping the tweak loaded (`watch.sh`)

Substrate cannot inject here (fact 2 below), so a relaunch of IMDb silently drops the tweak — and
"search is broken again" looks exactly like "the app was restarted". `watch.sh install` adds a
`LaunchDaemon` (`com.imdbrevival.watch`, `/var/root/imdb-watch.sh`) that watches `launchctl` for
the app's pid and calls `cynject` once per process, reading the dylib `deploy.sh` deployed, so a
new build is picked up on the next launch.

The alternative — inserting `LC_LOAD_WEAK_DYLIB` into a copy of `IMDb.app` — was rejected: it
means editing and re-signing a store-signed bundle (dumping it first if it is still FairPlay
encrypted), and a bad edit to the app binary is far harder to undo than two files and one
`launchctl unload`. The watcher changes nothing inside the app bundle.

It injects 2 s after the pid appears, because launchd lists an app before dyld has run its own
initialisers and injecting that early fails (`cynject` prints `_assert(false)`); failed attempts
are retried five times at 1 s. `./watch.sh remove <ip>` unloads the job and deletes both files;
`/Library/IMDbRevival/routes` and the dylib are left alone.

### Live data depends on `tlsfix.dylib`

The tweak reaches live IMDb hosts only because it `dlopen`s
`/Library/MobileSubstrate/DynamicLibraries/tlsfix.dylib` in its constructor before the first
request. The stock iOS 6 stack cannot complete a handshake with `sg.media-imdb.com` or
`api.graphql.imdb.com` — the error is `errSSLPeerHandshakeFail` (`-9824`), a cipher/version
mismatch, not a trust problem — and Substrate never loads tlsfix here, so the tweak loads it
itself. With it, live suggestions return `200` from inside the app; without it every live route
falls back to the archived fixtures, which is indistinguishable from "the network is down".

`deploy.sh` therefore checks for tlsfix and **refuses to deploy** when it is missing; set
`ALLOW_NO_TLSFIX=1` for a deliberate fixtures-only install. This is not a trust change and needs
no certificate or profile — see `docs` in the handover for the measurements.

`Tweak.x` is the pure-C load marker. `Tweak.xm` is the request-logging build
(NSURLConnection / UIWebView / NSMutableURLRequest hooks). Builds are armv7 against
`iPhoneOS6.1.sdk`, MRC, Foundation-only.

### The home screen: served, but empty (reconstruction, not capture)

On launch the app asks the template engine, not the app API:

```
GET https://api.imdbws.com/template/imdb-ios-writable/ipad-homepage-v2.jstl/render?showtimesRegion=US
    x-amzn-authorization: AWS3 AWSAccessKeyId=AKIAJ2TGR5WWERHW5FUA,Algorithm=HmacSHA256,…
    x-amz-date: Fri, 01 Apr 2011 10:23:56 GMT
    Accept: application/vnd.imdb.api+json
```

The path comes from `data.home_page.jstl` in `ios-app-config…/3.4.2/ipad.json.gz`, which also
carries the whole layout (`sections` → widgets `vi`, `inth`, `natvad`, `rec`).

**The response cannot be captured.** The host is alive on CloudFront, but it now answers
`403 {"message":"Request is missing Authentication Token"}`, the app's 2011 AWS3 signature is
rejected (`api.imdbws.com-403` in its own metrics), and the Wayback Machine holds only 403
snapshots of that path. No rendered body exists anywhere we can reach, and the app has no cached
copy (`Library/Caches/URLCache`, `AppConfigDict-3.4.2.data` contain nothing with `@jstlMeta`).

**What is known about the shape** comes from the app's own class metadata: the response is a Zulu
envelope (`@jstlMeta` with `responseType`, `serverTimeMs`, `requestId`, `timestamp`,
`subrequestTimes`) and `IMHomepageResponse` exposes exactly three collections — `trailers`,
`wideReleaseTitles`, `nativeAdArticles`.

`Tweak.xm` answers that path from `homepage.json` and refreshes `@jstlMeta.timestamp`, the same way
`exp` is refreshed for maindetails. Measured on the device: `serve api.imdbws.com … route=homepage.json
status=200`, the app accepts it, does not crash and stops reporting homepage network errors — but
**no widget data appears**: no poster requests, no recommendations request, no retry of the layout.
Seeding real titles into the three collections, and repeating them under several plausible
container keys (`data.homepage`, `data.render`, top level), changed nothing. The private template's
contract is not recoverable from the binary by inspection.

So the home tab stays empty. The route is kept anyway, because it replaces a `-1001` timeout (and
the app's `tapToATF.homepage.networkErrors` counter) with an immediate valid response; the home
screen itself is out of scope unless a real 2013 response turns up.

### The title page: reconstructed template, and it renders

Same engine, different document. Opening a title asks for both, at the same moment:

```
GET https://api.imdbws.com/template/imdb-ios-writable/title-auxiliary-v5b.jstl/render
    ?minwidth=480&region=PH&tconst=tt0133093&today=2011-04-01
GET https://app.imdb.com/title/tt0133093/maindetails?api=v1&…&sig=app9-…
```

The path comes from `data.title_page.jstl`, the layout from `data.title_page.sections` (widgets
`hero`, `titl`, `pstr`, `arate`, `oplot`, `drct`, `wrt`, `cast`, `phtos`, `gnrs`, `rdat`, `runt`, …).
The template body cannot be captured for the same reason as the home page (403 on the 2011 AWS3
signature), so `shim/build-title-aux.py` composes `title-auxiliary.json` from that layout plus
`md-2012.json`. Because the envelope is unknown it is a superset: the config `sections` with a
`data` object on every widget, a name→data `widgets` map, and the maindetails `data` at top level.

`Tweak.xm` serves any `api.imdbws.com/.../title-auxiliary*.jstl/render` from that file and refreshes
`@jstlMeta.timestamp` and `tconst`. Measured on the device (build `2.5-uiprobe`): `200
route=title-auxiliary.json` (31,052 B), `IMTabletTitlePageViewController` **and**
`IMTabletTitlePageAuxillaryViewController` appear, and the app then fetches eight cast thumbnails
from `ia.media-imdb.com` — the widgets received data and laid out a real page. One follow-up is
still unbuilt: `/title/fullcredits` is requested and answered `404`, so the full cast list is the
remaining gap on this screen.

That gap is now closed: `/title/fullcredits` is served from `fullcredits.json` (build
`2.6-fullcredits`, `200 route=fullcredits.json`), generated by `shim/build-fullcredits.py` from the
cast, director and writer summaries.

**Photos and posters were a separate failure.** The app composes image URLs itself as
`http://ia.media-imdb.com/images/…` whatever host the fixtures use, and that origin now answers plain
http with `403` — the same path over https is a `200` JPEG. Build `2.7-imageproxy` claims
`ia.media-imdb.com/images/*` and relays the path from `https://m.media-amazon.com`, so thumbnails
come back as `image/jpeg` instead of a 403 page (measured: four thumbnails, 2,381–2,800 B). The 2012
trailer still cannot play: its `totaleclips.com` URL answers `401`.

Both relays now share one `FetchHTTPS` helper, and relayed photos go through a bounded in-memory
cache keyed by the https URL (build `2.8-relaycache`): first open logs four `route=image-live`, the
second open four `route=image-cache`. A failed relay answers `404` and is logged as
`image-fail(<reason>)` — the first fetch after a cold relaunch can time out (`-1001`) and then
succeeds on the next open.

The poster is a separate, unresolved case: the app never requests its image at all. A
`setWidgetData:` hook on `IMTitlePagePosterWidget` logs **zero calls**, so the widget is never even
created — the data shape is not the reason. Supplying the data nested per widget, as a name-keyed
`widgets` map, and as name-keyed top-level keys, plus `image`/`poster`/`imageURL`/`posterURL`
aliases, changed nothing. The layout the app builds omits that widget; finding the lookup that feeds
it needs a recording hook, not more guessing.

### Every title gets its own name, year, stars and poster — and its own full cast (build `3.9-fullcredits`)

Until this build the title routes answered from `md-2012.json` and only substituted `tconst`, so
every film rendered Fight Club. The suggestion API is the one live endpoint that answers a bare
`tconst`, and it is the same host the app's search already uses — measured reachable from this
device with tlsfix (`200`, 2,146 B):

```
GET https://v3.sg.media-imdb.com/suggestion/t/tt0133093.json
{"d":[{"i":{"imageUrl":"https://m.media-amazon.com/…@._V1_.jpg","width":2100,"height":3156},
       "id":"tt0133093","l":"The Matrix","q":"feature","rank":349,
       "s":"Keanu Reeves, Laurence Fishburne","y":1999}],"q":"tt0133093","v":1}
```

So the per-title path needs no relay and no browser session. `FetchTitleInfo` resolves a `tconst`
from the cache first (every search the app runs is recorded by `id`, so tapping a result costs no
request), then from the endpoint above; the answer is cached and the miss is serialised, because
`maindetails` and `title-auxiliary` are asked for in parallel. `ServeRoute` then rewrites the
fixture's `data`: `title`, `year`, `type`, `image` (the poster), `photos`, `cast_summary` from `s`.
The auxiliary body gets the same values as a 34-name `widgets` map, and every widget node in
`sections` gets its `data` replaced to match — the layout carries its own copy, so patching only the
map is not enough.

**What is emptied on purpose.** The API knows five fields; a fixture's plot, quotes, trivia, reviews,
directors, genres, rating, votes, certificate, runtime and trailer belong to the film it was captured
for. They are removed rather than shown under another title's name, and `has` is emptied with them so
those widgets do not open empty sections. What remains on a per-title page is name, year, type,
poster and the two billed names.

**The poster is asked for as a thumb.** The API hands out the 2100×3156 original (3,728,582 B, the
byte count the reach probe logged); `PosterThumbURL` swaps the `_V1_.jpg` tail for `_V1_SX400.jpg`,
which returns the same image at 61,525 B. The poster *widget* is still never created (§ above), so
this changes the image the page can load, not whether that widget appears.

**Full cast follows the header.** `/title/fullcredits` was the last route still answering from the fixture, so the cast list contradicted the title above it. It now uses the same `FetchTitleInfo` answer: one `Cast` group holding the billed names, the right `data.title`/`tconst`, and the fixture's envelope and repeated payload keys (`credits`/`groups`/`list`) so the app parses it unchanged. The route often arrives without an id, so the `tconst` comes from the request when present and otherwise from the last title route this process answered. Characters, jobs and portraits are left empty — the API does not supply them, and the fixture's would be another film's. `/title/fullcredits` is therefore also answered on a worker thread now; three routes of one page share a single live request.

**Fallback.** A `tconst` with no live entry (measured: `tt9999999`) logs
`title_source=fixture` with the API's body head as the reason, and the page renders the archived film
exactly as before. Nothing throws away a working page to gain live data.

Measured on the device in one launch (`3.8-titleinfo`, four ids):

| tconst | source | name / year | stars | `maindetails` | `title-auxiliary` | `fullcredits` |
|---|---|---|---|---|---|---|
| tt0133093 | live | The Matrix / 1999 | Keanu Reeves, Laurence Fishburne | 914 B | 14,754 B, hero+layout+data = The Matrix | 2,238 B, 1 group = the 2 names |
| tt0068646 | live | The Godfather / 1972 | Marlon Brando, Al Pacino | 909 B | 14,745 B, hero+layout+data = The Godfather | 2,185 B, 1 group = the 2 names |
| tt0111161 | live | The Shawshank Redemption / 1994 | Tim Robbins, Morgan Freeman | 923 B | 14,809 B, hero+layout+data = The Shawshank Redemption | 2,217 B, 1 group = the 2 names |
| tt9999999 | fixture | Fight Club / 1999 | Brad Pitt, Edward Norton… | 8,888 B | 32,618 B, unchanged | 20,784 B, unchanged (3 groups, 4 cast) |

### OMDb and TMDB fill the page (build `4.2-omdb`)

The suggestion endpoint only knows name, year, two billed names and a poster. Two third-party APIs
report by IMDb id and are reachable from the device (both answer `401` JSON without a key, which the
old stack reports as `-1012` — an auth challenge, not a TLS failure):

| Source | Fills | Where it goes |
|---|---|---|
| OMDb `?i=<tconst>&plot=short` | plot, rating, votes, genres, runtime, certificate, release date, director, writers, actors, poster | `maindetails` `data` and the `oplot`/`plotd`/`arate`/`gnrs`/`runt`/`rdat`/`drct`/`wrt`/`hero` widgets |
| TMDB `find` → `/movie/<id>/credits` | full cast with character names and headshots | the `Cast` group of `fullcredits`, plus a `Directed by` group from OMDb |

Measured on the device: The Matrix 8.7 / 2,284,373 votes / 136 min / Action,Sci-Fi / 105-character
plot, `maindetails` 914 → **1,540 B**; TMDB returned **37** credits for the same id (Keanu Reeves as
"Neo", headshot URL included), fetched lazily on the full-credits route only.

**Keys are user-supplied and never committed.** The tweak reads `/Library/IMDbRevival/keys.plist`
(`OMDbAPIKey`, `TMDBAPIKey`) or the `com.imdbrevival.settings` preference domain — the place a
settings pane would write — so anybody who installs this can bring their own. One caveat found the
hard way: the file must be readable by the app's user (`644`). At `600 root` the app silently gets
nothing and the page falls back to what the suggestion API knows.

**The disk cache expires.** Each entry carries `fetched`; anything older than **30 days** is dropped
and refetched, so a wrong answer cannot stick for the life of the install.

### Never another film, and a cache that survives a relaunch (build `4.1-nofixturecache`)

The probe could never have caught this: it builds responses itself, so it always saw live data. A
real tap was the first true test, and it still showed Fight Club. Three causes were ruled out or
fixed in one pass:

1. **The fixture is no longer a fallback for a title route.** If nothing live is known for the
   `tconst`, the route answers for that id alone: identity fields empty, no cast, `has` empty. The
   archived film's name, plot and cast can no longer appear under another title. Measured with an id
   the API does not know (`tt9999999`): `maindetails` 491 B with `title = ""`, `title-auxiliary`
   11,324 B with no hero title and no cast, `fullcredits` 177 B — previously 8,888 / 32,618 / 20,784 B
   of Fight Club.
2. **Responses can no longer be cached by the client.** Every answer carries
   `Cache-Control: no-store, no-cache, must-revalidate`, `Pragma: no-cache` and `Expires: 0`. A cached
   body is how the same URL kept showing an old title after the data behind it changed.
3. **The title cache is filled by search and written to disk.** `Library/Caches/imdb-titleinfo.plist`
   in the app container held 24 entries (4,683 B) after one session. On the next cold start
   `titlecache load` reported `loaded = 24` and the three known ids produced **no suggestion request
   at all** — only the unknown id went to the network. A failed lookup is retried once after a second
   first, because the first request after launch is where `-1001` lives.

`/title/fullcredits` also only borrows the "last title route" `tconst` while it is under 5 s old;
otherwise it answers for the header alone rather than attaching a stranger's cast.

**OMDb and TMDB, measured.** Both hosts were probed from the device with tlsfix. Both returned
`-1012`, which is *not* a handshake failure: from the Mac each answers `HTTP 401` with a JSON body
on a valid TLS connection. `-1012` is an authentication challenge the old stack cancels when no
credential exists. The probe now labels it `reachable-auth` instead of `tls-wall`. Wiring either
service up needs a key; nothing is implemented until one exists, because the happy path would be
unverifiable.

## Two device-specific facts that shape everything here

**1. armv7 dylibs from a modern toolchain must be built `-marm`.** Such a dylib is compiled
Thumb-2 but `ld` writes **even** pointers into `__DATA,__mod_init_func`; iOS 6's dyld trusts the
low bit, calls the initialiser in ARM mode, decodes the Thumb stream as garbage and the host
process dies with SIGILL **before `main()`** — after the image has mapped, with no diagnostic.
That is what made the tweak look like it never loaded and made Substrate look broken. Verified by
building the same source both ways (`-mthumb` → rc=132, `-marm` → rc=0). `-marm` in the Makefile
is mandatory and must never be dropped, and it applies to every armv7 helper, not just the tweak.

Unsigned dylibs are the other trap: Theos prints `==> Signing` but has produced a binary with no
`LC_CODE_SIGNATURE`, which iOS 6 also traps on load. `deploy.sh` signs with `ldid -S` when needed
and refuses to install an unsigned dylib (exit 8).

**2. Substrate injects into no newly spawned process on this boot.** With a correct, signed dylib
and a valid filter plist, a freshly launched app contains neither `MobileSubstrate.dylib` nor our
dylib — and `DYLD_INSERT_LIBRARIES` is unset even in a launchd-spawned `sshd` shell, so Substrate's
launchd hook is not running at all. The same dylib injects fine by hand with
`cynject <pid> <dylib>`, so this is a loader-level problem, not a tweak problem.
`/etc/launchd.conf` holds `bsexec .. /usr/bin/cynject 1 …SubstrateLauncher.dylib`, which is how
Substrate is meant to bootstrap; on 6.1.3 it appears not to be processed. **Do not edit that file**
— worst case it breaks the jailbreak. `./watch.sh install` works around it by re-injecting per
launch; by hand it is `cynject $(launchctl list | grep -i imdb | cut -f1) <dylib>`.

Consequence for the capture work: the Mac-side `shim/` remains the reference implementation, and
the on-device tweak is driven by hand. Crashes seen while testing were watchdog kills
(`0x8badf00d`) caused by launching the app over SSH (`uiopen`), which also happens with no tweak
installed — they are not caused by the tweak.

### What the device can reach with tlsfix (measured 2026-11-24, build `3.7-reach`)

`Tweak.xm` has a host-matrix probe (`IMDBLiveTest`) that runs at load when
`/Library/IMDbRevival/livetest` exists, fetches each candidate one at a time on a background
thread, and writes one `livetest` line per target with `status`, `bytes`, `ms`, `ctype`, `head` and
a `verdict` (`usable` = 200 with a body, `reachable` = handshake completed but no usable body,
`tls-wall` = an `NSError` came back). Measured in-process, tlsfix loaded:

| target | URL | result | verdict |
|---|---|---|---|
| `sg-raw` | `sg.media-imdb.com/suggests/t/the.json` | 200, 1,874 B, JSONP | usable |
| `v3-raw` | `v3.sg.media-imdb.com/suggestion/t/the.json` | 200, 2,146 B, JSON | usable |
| `amazon-image` | `m.media-amazon.com/images/M/…jpg` | 200, 3,728,582 B, `image/jpeg` | usable |
| `www-title` | `www.imdb.com/title/tt0133093/` | 202, **0 B** | reachable |
| `www-browser` | same, Chrome UA + Origin/Referer/Accept | 202, 1,997 B challenge page | reachable |
| `m-title` | `m.imdb.com/title/tt0133093/` | 202, 0 B | reachable |
| `graphql-api` | `api.graphql.imdb.com/` (POST) | **403**, 919 B CloudFront "Request blocked" | reachable |
| `graphql-cache` | `caching.graphql.imdb.com/` (POST) | 403, 919 B, same page | reachable |
| `graphql-browser` | same, browser headers | 403, 919 B, same page | reachable |

**The TLS wall is gone.** Every target completed a handshake; not one produced an `NSError`. The
earlier `-9824` / `-1200` failures were purely the missing tlsfix, not the hosts.

**The new wall is at the edge, and it is not device-specific.** The same `curl` from the Mac
returns byte-identical results — `202`/0 B for the title page with either UA, and the same 919-byte
CloudFront "Request blocked" page for GraphQL. Plain HTTP clients are refused at the CDN for both
hosts, so a relay on the Mac would gain nothing: it hits the same block. What still works over plain
HTTPS is the suggestion API (title, year, stars, poster per tconst) and the image CDN.

So live per-title data needs either a relay that carries a *real browser session* (cookies/JS
challenge solved on the Mac, results reshaped into the `md-2012` envelope — the device is not the
obstacle) or no live fetch at all: suggestions + a prebuilt title pack, both of which the device
can already fetch/serve itself. Re-run the matrix any time with
touch /Library/IMDbRevival/livetest && relaunch.

## imdb-capture

`./run-capture.sh` starts mitmproxy on `:8080` with an addon that writes `traffic.jsonl`,
`traffic.log` and response bodies. Point the device's Wi-Fi HTTP proxy at the Mac and install
the CA from `http://mitm.it`. `python3 summarize.py` groups captured requests into endpoint
templates with status codes. Verified intercepting HTTPS from a device.

## Next steps

1. Resolve loading. Injection works by hand (`cynject <pid> <dylib>`) but not at launch; the
   options, in order, are repairing Substrate's launchd bootstrap (risky, needs approval), adding
   an `LC_LOAD_WEAK_DYLIB` to `IMDb.app` and re-signing with `ldid` (keep an off-device copy
   first), or a watcher that `cynject`s after each launch.
2. Capture the `/title/<id>/maindetails` chain. One title tap produces it; nothing has tapped a
   title yet, so `maindetails` has never been seen. Note the request carries a per-request
   `sig=app9-<40 hex>` parameter (e.g. `/hello?api=v1&appid=ipad3_4_2&…&sig=app9-…`).
3. Implement that route in the tweak as a transform into the legacy envelope (`md-2012.json` is
   the contract, `exp` must be in the future). Live data is **not** a drop-in: this device's TLS
   reaches `m.media-amazon.com` but fails `sg.media-imdb.com` and `api.graphql.imdb.com` with
   `-1200`, so live filling needs a bundled TLS client or a relay.
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
- hosts that still answer upstream (`sg.media-imdb.com`, `ios-app-config.media-imdb.com`,
  `ia.media-imdb.com`, `www.imdb.com`, `imdb.com`, `api.imdbws.com`, `secure.imdb.com`) are
  relayed: the shim fetches them over HTTPS and returns the body over plain HTTP, so search
  suggestions and app config keep working on the device with no TLS. `app.imdb.com` is never
  relayed - it refuses connections - and its routes are the local ones above
- everything else -> JSON 404, still logged

Every log line records `status`, `bytes` and `proxied`, so a 404 on search is visible as such.
`--no-proxy` gives a log-only run.

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

### TLS: the title API is HTTPS

The app bootstrap (config, search suggestions) is plain HTTP, but tapping a title opens
**TLS** to `app.imdb.com` and `api.imdbws.com` - visible as ClientHellos with those SNI names
on port 443. A listener on port 80 therefore never sees a title request. The same routes are
served on 443 with a local certificate:

```bash
./make-cert.sh                     # self-signed, SANs for the imdb hosts
python3 server.py --port 443 --tls-cert certs/imdb-shim.pem --tls-key certs/imdb-shim.key
```

Both instances append to `requests.jsonl` and every line records `scheme`, so the HTTP/HTTPS
split stays visible. If the device refuses the certificate, no request is logged and the app
shows a network error - that means a CA/trust profile has to be installed on the device, which
is a device change to agree to first.

The `imdb-tweak` `NSURLProtocol` intercepts **above** TLS, so for the on-device path none of this
is needed: no certificate, no CA profile, no hosts entry, no listening port. The 443 listener is
kept only as a diagnostic for measuring what the device itself can handshake with.

Both the Mac and the iPad are on DHCP here — re-check `ipconfig getifaddr en0` before wiring the
device, since the shim host address has already moved once.
