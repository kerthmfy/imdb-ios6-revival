#!/usr/bin/env python3
"""Rebuild shim/fixtures/title-auxiliary.json from the app config + md-2012.json.

The real `title-auxiliary-v5b.jstl/render` body was never captured: api.imdbws.com
rejects the app's 2011 AWS3 signature with 403 and no archived copy exists. This
composes the best-supported reconstruction from three sources we do have:

  * data.title_page.sections in the app config  -> the layout the app expects,
    including every widget name (`hero`, `pstr`, `arate`, ...);
  * the app's own class metadata                -> `@jstlMeta` envelope and the
    per-widget `data` that `setWidgetData:` consumers read;
  * md-2012.json                                -> the values.

Because the exact envelope is unknown, the output is a superset: the config
sections with a `data` object on every widget, a name->data `widgets` map, and
the maindetails `data` at top level. Extra keys are ignored by NSDictionary
readers; a missing one is what breaks a page.
"""
import json
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent
CONFIG = ROOT / "fixtures/ios-app-config/3.4.2/ipad.pretty.json"
MD = ROOT / "fixtures/md-2012.json"
OUT = ROOT / "fixtures/title-auxiliary.json"


def load():
    cfg = json.loads(CONFIG.read_text())["data"]["title_page"]
    md = json.loads(MD.read_text())["data"]
    return cfg, md


def widget_data(md):
    """Per-widget `data`, keyed by the widget names the config uses."""
    plot = md.get("plot") or {}
    image = md.get("image") or {}
    rating = md.get("rating")
    votes = md.get("num_votes")
    runtime = (md.get("runtime") or {}).get("time")
    trailer = md.get("trailer") or {}
    photos = []
    for p in (md.get("photos") or [])[:12]:
        img = p.get("image") or {}
        if img.get("url"):
            photos.append({"image": {"url": img["url"],
                                     "width": img.get("width", 0),
                                     "height": img.get("height", 0)}})

    hero = {
        "tconst": md.get("tconst"),
        "title": md.get("title"),
        "year": md.get("year"),
        "type": md.get("type"),
        "certificate": md.get("certificate"),
        "rating": rating,
        "num_votes": votes,
        "runtime": runtime,
        "image": image,
        "genres": md.get("genres") or [],
    }
    # One block per widget name in the config. Widgets whose data we cannot
    # produce get an empty dict: better an empty widget than the whole page
    # failing because a key is absent.
    return {
        "hero": hero,
        "titl": {"title": md.get("title"), "year": md.get("year"), "type": md.get("type")},
        "pstr": {"image": image},
        "arate": {"rating": rating, "num_votes": votes},
        "urate": {},
        "meta": {"metascore": md.get("metascore")} if md.get("metascore") else {},
        "oplot": {"plot": plot.get("outline", ""), "has_more": bool(plot.get("more"))},
        "plotd": {"plot": plot.get("outline", ""), "has_more": bool(plot.get("more"))},
        "drct": {"people": md.get("directors_summary") or []},
        "wrt": {"people": md.get("writers_summary") or []},
        "cast": {"people": md.get("cast_summary") or []},
        "phtos": {"photos": photos},
        "plytlr": trailer,
        "tAwrd": {},
        "t250": {},
        "pulq": {},
        "triv": {"trivium": md.get("trivium") or []},
        "quot": {"quote": md.get("quote") or []},
        "goof": {"goof": md.get("goof") or []},
        "crzy": {},
        "sndt": {},
        "tgln": {"tagline": md.get("tagline", "")},
        "gnrs": {"genres": md.get("genres") or []},
        "rdat": {"release_date": md.get("release_date")},
        "lang": {},
        "altt": {},
        "loctn": {},
        "runt": {"runtime": runtime},
        "altv": {},
        "sims": {},
        "conns": {},
        "imdbWS": {"tconst": md.get("tconst")},
        "crev": {},
        "ocrev": {},
    }


def decorate(node, data):
    """Copy the config node, attaching `data` to every widget."""
    if isinstance(node, list):
        return [decorate(n, data) for n in node]
    if not isinstance(node, dict):
        return node
    out = {k: decorate(v, data) for k, v in node.items() if k != "items"}
    if node.get("type") == "widget":
        name = node.get("name")
        if name:
            out["data"] = data.get(name, {})
    if "items" in node:
        out["items"] = decorate(node["items"], data)
    return out


def main():
    cfg, md = load()
    data = widget_data(md)
    payload = {
        "@type": "title-auxiliary",
        "@jstlMeta": {
            "responseType": "title-auxiliary",
            "requestId": "imdb-revival-local",
            "serverTimeMs": 12,
            "timestamp": int(time.time()),
            "subrequestTimes": {"title-auxiliary": 12},
        },
        "tconst": md.get("tconst"),
        "title": md.get("title"),
        "sections": decorate(cfg["sections"], data),
        "widgets": data,
        "data": md,
    }
    OUT.write_text(json.dumps(payload, indent=1, sort_keys=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT.parent.parent)} "
          f"({OUT.stat().st_size} B, {len(data)} widget names)")


if __name__ == "__main__":
    main()
