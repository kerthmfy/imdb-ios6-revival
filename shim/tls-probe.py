#!/usr/bin/env python3
"""Log TLS connection attempts and their SNI, then close.

No certificate, no handshake: this exists only to answer 'is the app speaking
HTTPS, and to which host?'. Answers go to tls-probe.jsonl.
"""
import json, re, socket, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 443
LOG = "tls-probe.jsonl"


def parse_sni(data):
    try:
        # TLS record header (5) + handshake header (4) = ClientHello body
        i = 43  # fixed offset past version/random
        i += 1 + data[i]                    # session id
        i += 2 + int.from_bytes(data[i:i + 2], "big")   # cipher suites
        i += 1 + data[i]                    # compression methods
        i += 2                              # extensions length
        end = len(data)
        while i + 4 <= end:
            etype = int.from_bytes(data[i:i + 2], "big")
            elen = int.from_bytes(data[i + 2:i + 4], "big")
            if etype == 0:                  # server_name
                j = i + 4 + 2               # skip list length
                j += 1 + 2                  # name type + name length
                return data[j:j + elen - 3].decode("ascii", "replace")
            i += 4 + elen
    except Exception:
        pass
    m = re.search(rb"([a-z0-9][a-z0-9\-.]{2,60}\.(?:com|net|org|ws))", data or b"")
    return m.group(1).decode() if m else None


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(50)
print(f"tls-probe listening on :{PORT}", flush=True)

with open(LOG, "a", buffering=1) as log:
    while True:
        conn, addr = srv.accept()
        conn.settimeout(4)
        data = b""
        try:
            data = conn.recv(8192)
        except Exception:
            pass
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "from": addr[0],
            "bytes": len(data),
            "looks_tls": bool(data[:1] == b"\x16"),
            "sni": parse_sni(data) if data[:1] == b"\x16" else None,
            "head": data[:24].hex(),
        }
        log.write(json.dumps(rec) + "\n")
        print(json.dumps(rec), flush=True)
        try:
            conn.close()
        except Exception:
            pass
