#!/usr/bin/env python3
"""Minimal app.imdb.com shim for IMDb 3.4.2 on iOS 6.

Answers the routes the app needs before it will render anything:

    /hello                              session bootstrap -> { data: { time, status, api_key } }
    /title/<tconst>/maindetails         archived maindetails payload with a future exp
    /title/maindetails?tconst=<tconst>  same, query-string variant seen in 2012

Everything else returns a JSON 404. Every request is appended to requests.jsonl,
so the log doubles as the traffic capture the device-side tweak never produced.

Plain HTTP on purpose: the app builds its URLs as `http://imdb.com%@`, so no
certificate install is needed on the device.

    python3 server.py --port 8080
    python3 server.py --port 80        # needs root; this is what the device needs
"""
import argparse
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
REQUEST_LOG = os.path.join(HERE, "requests.jsonl")

# The key the real /hello returned in 2011. Any value works while we are the server,
# so we echo the one the client was originally built against.
API_KEY = "XXIE9umhSbJ+Uv1uTp7hLQ"
TTL_SECONDS = 3600

COPYRIGHT = (
    "For use only by clients authorized in writing by IMDb.  Authors and users of "
    "unauthorized clients accept full legal exposure/liability for their actions."
)

TITLE_PATH = re.compile(r"^/title/(tt\d+)/maindetails/?$")


def load_fixture(name):
    path = os.path.join(FIXTURES, name)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def envelope(data, with_exp=True):
    """Wrap payload in the legacy envelope. exp must be in the future or the
    client treats the response as stale."""
    doc = {}
    if with_exp:
        doc["exp"] = int(time.time()) + TTL_SECONDS
    doc["data"] = data
    doc["copyright"] = COPYRIGHT
    return doc


def hello_payload():
    return {
        "data": {"time": int(time.time()), "status": "ok", "api_key": API_KEY},
        "copyright": COPYRIGHT,
    }


def maindetails_payload(tconst):
    """Archived maindetails, retargeted at the requested id.

    MVP: the body is the archived fixture (2012 first, 2010 fallback), so every
    title renders the same film but with the correct tconst echoed.
    """
    try:
        doc = load_fixture("md-2012.json")
    except FileNotFoundError:
        doc = load_fixture("md-2010.json")
    data = doc["data"]
    data["tconst"] = tconst
    return envelope(data)


class ShimHandler(BaseHTTPRequestHandler):
    server_version = "imdb-shim/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stderr quiet; we log JSONL instead
        pass

    def _record(self):
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "method": self.command,
            "path": self.path,
            "host": self.headers.get("Host", ""),
            "ua": self.headers.get("User-Agent", ""),
        }
        with open(REQUEST_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        sys.stderr.write("%s %s %s\n" % (entry["method"], entry["path"], entry["host"]))
        sys.stderr.flush()

    def _send_json(self, status, doc):
        body = json.dumps(doc).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        self._record()
        parsed = urlparse(self.path)
        path = parsed.path

        if path.rstrip("/") in ("/hello", ""):
            return self._send_json(200, hello_payload())

        match = TITLE_PATH.match(path)
        if match:
            return self._send_json(200, maindetails_payload(match.group(1)))

        if path.rstrip("/") == "/title/maindetails":
            tconst = (parse_qs(parsed.query).get("tconst") or ["tt0133093"])[0]
            return self._send_json(200, maindetails_payload(tconst))

        return self._send_json(404, envelope({"error": "not implemented in shim MVP", "path": path}))

    do_HEAD = do_GET


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    httpd = ThreadingHTTPServer((args.host, args.port), ShimHandler)
    print("imdb-shim listening on http://%s:%d" % (args.host, args.port))
    print("  /hello                        -> api_key envelope")
    print("  /title/<tconst>/maindetails   -> archived maindetails, future exp")
    print("  requests -> %s" % REQUEST_LOG)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
