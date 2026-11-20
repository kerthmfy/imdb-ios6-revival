#!/usr/bin/env python3
"""Minimal app.imdb.com shim for IMDb 3.4.2 on iOS 6.

Answers the routes the app needs before it will render anything:

    /hello                              session bootstrap -> { data: { time, status, api_key } }
    /title/<tconst>/maindetails         archived maindetails payload with a future exp
    /title/maindetails?tconst=<tconst>  same, query-string variant seen in 2012

Everything else returns a JSON 404 -- unless the request names a host that is
still alive upstream (see PROXY_HOSTS), in which case the shim relays it over
HTTPS and hands the body back to the device over plain HTTP. That keeps search
suggestions, config and images working with no TLS on the device, while every
request is still captured.

Every request is appended to requests.jsonl with host, full path, query, UA and
the status/byte count actually served, so the log doubles as the traffic
capture the device-side tweak never produced (MobileSubstrate injection is
broken on this iPad; the shim is the only capture path).

Plain HTTP on the device side on purpose: the app builds its URLs as
`http://imdb.com%@`, so no certificate install is needed.

    python3 server.py --port 8080
    python3 server.py --port 80        # needs root; this is what the device needs
    python3 server.py --port 80 --no-proxy   # log-only: 404 everything unknown

TLS: the app fetches config and search over plain HTTP but opens **HTTPS** to
`app.imdb.com` (and `api.imdbws.com`) as soon as a title is tapped, so port 80
alone can never answer a title page. Pass --tls-cert/--tls-key to serve the same
routes on 443; both instances append to the same log and each line records its
`scheme`, which is how the HTTP-vs-HTTPS split was discovered.
"""
import argparse
import http.client
import json
import os
import re
import ssl
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
UPSTREAM_TIMEOUT = 12

# Hosts that still answer in 2026. Their requests are fetched over HTTPS from
# this machine and relayed to the device as plain HTTP, so the app sees the old
# cleartext protocol while the real service keeps working.
#
# app.imdb.com is deliberately absent: it is dead, and its routes are the ones
# this shim implements. Mapping it through would just add a timeout to every
# request the app makes.
PROXY_HOSTS = {
    "sg.media-imdb.com",
    "ia.media-imdb.com",
    "m.media-amazon.com",
    "www.imdb.com",
    "imdb.com",
    "ios-app-config.media-imdb.com",
    "api.imdbws.com",
    "secure.imdb.com",
}

COPYRIGHT = (
    "For use only by clients authorized in writing by IMDb.  Authors and users of "
    "unauthorized clients accept full legal exposure/liability for their actions."
)

TITLE_PATH = re.compile(r"^/title/(tt\d+)/maindetails/?$")

PROXY_ENABLED = True


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
    server_version = "imdb-shim/0.2"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stderr quiet; we log JSONL instead
        pass

    # ---------------------------------------------------------------- logging
    def _record(self, host, parsed, status, nbytes, proxied):
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "scheme": "https" if isinstance(self.request, ssl.SSLSocket) else "http",
            "method": self.command,
            "raw_path": self.path,
            "path": parsed.path,
            "query": parsed.query,
            "host": self.headers.get("Host", ""),
            "hostname": host,
            "status": status,
            "bytes": nbytes,
            "proxied": proxied,
            "ua": self.headers.get("User-Agent", ""),
            "accept": self.headers.get("Accept", ""),
            "body_len": int(self.headers.get("Content-Length") or 0),
        }
        with open(REQUEST_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        sys.stderr.write("%s %s %s -> %s (%d B%s)\n" % (
            entry["method"], host or "-", self.path, status, nbytes,
            ", proxied" if proxied else ""))
        sys.stderr.flush()

    # --------------------------------------------------------------- upstream
    def _fetch_upstream(self, host):
        """Relay the request to https://<host><path>. Returns (status, body, ctype)."""
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(host, timeout=UPSTREAM_TIMEOUT, context=ctx)
        headers = {
            "Host": host,
            "User-Agent": self.headers.get("User-Agent", "imdb-shim/0.2"),
            "Accept": self.headers.get("Accept", "*/*"),
            "Accept-Encoding": "identity",  # device gets the bytes as-is
        }
        try:
            conn.request("GET", self.path, headers=headers)
            resp = conn.getresponse()
            body = resp.read()
            ctype = resp.getheader("Content-Type", "application/octet-stream")
            return resp.status, body, ctype
        except Exception as exc:  # noqa: BLE001 - report, never crash the server
            detail = "%s: %s" % (type(exc).__name__, exc)
            body = json.dumps({"error": "upstream failed", "host": host, "detail": detail}).encode()
            return 502, body, "application/json"
        finally:
            conn.close()

    # ----------------------------------------------------------------- output
    def _send(self, status, body, ctype):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        host = (self.headers.get("Host") or "").split(":")[0].strip().lower()

        proxied = False
        status, body, ctype = 404, b"", "application/json"

        if path.rstrip("/") in ("/hello", ""):
            status, body = 200, json.dumps(hello_payload()).encode()
        elif TITLE_PATH.match(path):
            status, body = 200, json.dumps(maindetails_payload(TITLE_PATH.match(path).group(1))).encode()
        elif path.rstrip("/") == "/title/maindetails":
            tconst = (parse_qs(parsed.query).get("tconst") or ["tt0133093"])[0]
            status, body = 200, json.dumps(maindetails_payload(tconst)).encode()
        elif PROXY_ENABLED and host in PROXY_HOSTS:
            status, body, ctype = self._fetch_upstream(host)
            proxied = True
        else:
            body = json.dumps(envelope({
                "error": "not implemented in shim",
                "path": path,
                "host": host,
                "proxy_hosts": sorted(PROXY_HOSTS) if PROXY_ENABLED else [],
            })).encode()

        self._send(status, body, ctype)
        self._record(host, parsed, status, len(body), proxied)

    do_HEAD = do_GET


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--no-proxy", action="store_true",
                    help="log only: never contact upstream hosts, 404 unknown routes")
    ap.add_argument("--tls-cert", help="serve HTTPS with this PEM certificate")
    ap.add_argument("--tls-key", help="private key for --tls-cert")
    args = ap.parse_args()

    global PROXY_ENABLED
    PROXY_ENABLED = not args.no_proxy

    httpd = ThreadingHTTPServer((args.host, args.port), ShimHandler)
    scheme = "http"
    if args.tls_cert and args.tls_key:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    print("imdb-shim listening on %s://%s:%d" % (scheme, args.host, args.port))
    print("  /hello                        -> api_key envelope")
    print("  /title/<tconst>/maindetails   -> archived maindetails, future exp")
    print("  %s -> HTTPS passthrough for: %s" % (
        "proxying" if PROXY_ENABLED else "NOT proxying", ", ".join(sorted(PROXY_HOSTS))))
    print("  requests -> %s (each line records scheme)" % REQUEST_LOG)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
