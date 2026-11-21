#!/usr/bin/env python3
"""Build shim/fixtures/fullcredits.json from md-2012.json.

The title page fetches /title/fullcredits separately from maindetails; the
legacy app renders its cast list (and the actor photos) from that response, so
without it the page shows an empty cast section.

Keys are taken from the app's own classes: IMTitleFullCreditsAppResponse has
`title` and `groups`; IMCreditGroup holds a list of credits or nested groups;
IMCredit has `name` (with `image`), `char`, `characters`, `job`, `as`. The exact
key names of the wrapper were never captured, so each group and each credit
repeats its payload under every candidate key (`credits` / `groups` / `list`)
and extras are ignored by NSDictionary readers.
"""
import json
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent
MD = ROOT / "fixtures/md-2012.json"
OUT = ROOT / "fixtures/fullcredits.json"


def credit(person, char=None, attr=None):
    name = person.get("name") or {}
    out = {
        "name": name,
        "char": char or "",
        "character": char or "",
        "characters": [char] if char else [],
        "hasCharacter": bool(char),
        "job": "",
        "as": person.get("as") or attr or "",
        "attribution": attr or "",
    }
    if isinstance(name, dict) and name.get("image"):
        out["image"] = name["image"]
    return out


def group(title, credits):
    return {
        "name": title,
        "title": title,
        "category": title.lower(),
        "totalCreditsCount": len(credits),
        "credits": credits,
        "groups": credits,
        "list": credits,
    }


def modern_image(obj):
    """See build-title-aux.py: ia.media-imdb.com over http now answers 403, so
    every image URL is moved to the https host that still serves the same path."""
    if isinstance(obj, dict):
        return {k: modern_image(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [modern_image(v) for v in obj]
    if isinstance(obj, str) and "ia.media-imdb.com" in obj:
        return obj.replace("http://ia.media-imdb.com/", "https://m.media-amazon.com/")
    return obj


def main():
    md = json.loads(MD.read_text())["data"]
    cast = [credit(c, char=c.get("char")) for c in (md.get("cast_summary") or [])]
    directors = [credit(p) for p in (md.get("directors_summary") or [])]
    writers = [credit(p, attr=p.get("attr")) for p in (md.get("writers_summary") or [])]

    groups = []
    if cast:
        groups.append(group("Cast", cast))
    if directors:
        groups.append(group("Directed by", directors))
    if writers:
        groups.append(group("Writing credits", writers))

    payload = {
        "exp": int(time.time()) + 3600,
        "@meta": {"serverTimeMs": 21, "requestId": "imdb-revival-local"},
        "data": {
            "tconst": md.get("tconst"),
            "title": md.get("title"),
            "groups": groups,
            # Same content under the other names the response classes expose.
            "credits": groups,
            "cast": cast,
            "totalCreditsCount": sum(len(g["credits"]) for g in groups),
        },
    }
    payload = modern_image(payload)
    OUT.write_text(json.dumps(payload, indent=1) + "\n")
    print(f"wrote {OUT.name}: {OUT.stat().st_size} B, "
          f"{len(cast)} cast, {len(directors)} directors, {len(writers)} writers")


if __name__ == "__main__":
    main()
