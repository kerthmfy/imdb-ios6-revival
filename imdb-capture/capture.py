"""
mitmproxy addon: capture IMDb (iOS 6) traffic.

Run via:  ./run-capture.sh

Writes:
  traffic.jsonl   one JSON object per request/response
  traffic.log     human-readable one-liners
  bodies/         response bodies for imdb-related hosts (truncated)

Host filters are deliberately broad: we do not yet know which backend the
3.4.2 build uses, so everything is recorded and tagged.
"""

import json
import os
import time
from urllib.parse import urlparse

from mitmproxy import http

HERE = os.path.dirname(os.path.abspath(__file__))
JSONL = os.path.join(HERE, "traffic.jsonl")
LOG = os.path.join(HERE, "traffic.log")
BODIES = os.path.join(HERE, "bodies")

# hosts we care about enough to keep the body of
INTERESTING = (
    "imdb",
    "media-imdb",
    "amazon",
    "aiv-cdn",
    "cloudfront",
)

MAX_BODY = 400_000


def _interesting(host: str) -> bool:
    h = (host or "").lower()
    return any(tag in h for tag in INTERESTING)


def _ensure_dirs() -> None:
    os.makedirs(BODIES, exist_ok=True)


def _append(path: str, text: str) -> None:
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(text)


def _safe_name(flow: http.HTTPFlow) -> str:
    u = urlparse(flow.request.pretty_url)
    base = (u.netloc + u.path).replace("/", "_").replace(":", "_")
    base = "".join(c if c.isalnum() or c in "._-" else "-" for c in base)
    return f"{(flow.id or str(time.time()))[:8]}_{base[:120]}"


def request(flow: http.HTTPFlow) -> None:
    _ensure_dirs()
    rec = {
        "kind": "request",
        "ts": time.time(),
        "id": flow.id,
        "method": flow.request.method,
        "scheme": flow.request.scheme,
        "host": flow.request.host,
        "port": flow.request.port,
        "path": flow.request.path,
        "headers": dict(flow.request.headers),
    }
    _append(JSONL, json.dumps(rec) + "\n")


def response(flow: http.HTTPFlow) -> None:
    _ensure_dirs()
    resp = flow.response
    ctype = resp.headers.get("content-type", "")
    body_preview = ""
    body_file = ""

    if _interesting(flow.request.host):
        raw = resp.get_content() or b""
        truncated = raw[:MAX_BODY]
        try:
            text = truncated.decode("utf-8", "replace")
        except Exception:
            text = "<binary>"
        body_preview = text[:600].replace("\n", " ")

        body_file = os.path.join(BODIES, _safe_name(flow) + ".txt")
        try:
            with open(body_file, "w", encoding="utf-8") as fh:
                fh.write(f"{flow.request.method} {flow.request.pretty_url}\n")
                fh.write(f"status: {resp.status_code}\n")
                for k, v in resp.headers.items():
                    fh.write(f"{k}: {v}\n")
                fh.write("\n")
                fh.write(text)
        except Exception:
            body_file = ""

    rec = {
        "kind": "response",
        "ts": time.time(),
        "id": flow.id,
        "method": flow.request.method,
        "host": flow.request.host,
        "path": flow.request.path,
        "status": resp.status_code,
        "content_type": ctype,
        "bytes": len(resp.get_content() or b""),
        "body_file": body_file,
        "preview": body_preview,
    }
    _append(JSONL, json.dumps(rec) + "\n")

    line = (
        f"{resp.status_code:<4} {len(resp.get_content() or b''):>7}B "
        f"{flow.request.method:<4} {flow.request.scheme}://"
        f"{flow.request.host}{flow.request.path[:140]}\n"
    )
    _append(LOG, line)


def error(flow: http.HTTPFlow) -> None:
    _ensure_dirs()
    rec = {
        "kind": "error",
        "ts": time.time(),
        "id": flow.id,
        "method": flow.request.method,
        "host": flow.request.host,
        "path": flow.request.path,
        "error": str(flow.error) if flow.error else "",
    }
    _append(JSONL, json.dumps(rec) + "\n")
    _append(LOG, f"ERR  {flow.request.host}{flow.request.path[:140]}  "
                 f"{flow.error}\n")
