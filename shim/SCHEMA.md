# app.imdb.com legacy JSON API — recovered shapes

Captured from the Wayback Machine (`id_` raw snapshots), not inferred. The host `app.imdb.com`
itself no longer accepts connections, so these fixtures are the only remaining ground truth.

## Envelope

```json
{ "exp": 1355315558, "@meta": { "serverTimeMs": 21, "requestId": "..." },
  "data": { ... }, "copyright": "For use only by clients authorized in writing by IMDb..." }
```

- `exp` is a **unix timestamp**: expiry of the payload. A shim must emit a future value or the
  client may treat every response as stale.
- `@meta` appears in 2012-era responses.
- `/hello` omits `exp`.

## Endpoints captured

| Route | Fixture | `data` shape |
|---|---|---|
| `/title/<tconst>/maindetails` (2010) and `/title/maindetails?tconst=` (2012) | `md-2010.json`, `md-2012.json` | 18-26 keys, see below |
| `/chart/top` | `chart-top.json` | `{ list: [...] }` |
| `/feature/comingsoon` | `comingsoon.json` | `{ country, list: [...] }` |
| `/boxoffice` | `boxoffice.json` | `{ date, list: [...] }` |
| `/hello?appid=unauth` | `hello.json` | `{ time, status, api_key }` |

## `maindetails` keys (2012 snapshot)

`best_plot, can_rate, cast_summary, certificate, directors_summary, genres, goof, has, image,
news, num_votes, photos, plot, quote, rating, release_date, runtime, tagline, tconst, title,
trailer, trivium, type, user_comment, writers_summary, year`

Notes on the shapes that matter:

- `has` is a **string array** that drives which widgets the client renders:
  `["more_cast","trivia","goofs","quotes","more_plot","parentalguide","synopsis","user_comments","external_reviews","photos"]`.
  Omit entries and the corresponding sections disappear.
- `plot` = `{ outline, more }`; `best_plot` = `{ outline, total_summaries }`
- `runtime` = `{ time: <seconds> }` (8340 = 139 min)
- `release_date` = `{ normal: "YYYY-MM-DD" }`
- `photos[]` = `{ link, image: { url, width, height } }`
- `directors_summary[]` / `writers_summary[]` = `{ name: { nconst, name, image: { url, width, height } } }`
- `user_comment` = `{ user_rating, date, status, user_name, summary, user_score, text, user_location, user_score_count }`
- `trailer` = `{ encodings, slates, content_type, duration_seconds, id, title, description, relatedTitle, relatedName }`

## `/hello` is the interesting one

`{ "data": { "time": ..., "status": ..., "api_key": "..." } }` — a session bootstrap yielding an
`api_key`. If the client blocks until this succeeds, a shim must answer `/hello` **before** any
other route, otherwise the app can appear to hang with no requests in flight.

## Images

Fixtures reference `ia.media-imdb.com`; the live search API now returns `m.media-amazon.com`.
Both are HTTPS-capable on iOS 6 only via TLSFix, which is already installed on the test device.
