#!/usr/bin/env python3
"""Summarize shim/requests.jsonl by host and path.

    python3 summarize.py                     # grouped summary of the default log
    python3 summarize.py --app-only          # only the IMDb app's own requests
    python3 summarize.py --timeline          # chronological order, no grouping
    python3 summarize.py --errors            # only non-2xx responses
    python3 summarize.py other.jsonl         # a different log

The log is one JSON object per request (server.py appends it), with older lines
predating some fields; missing keys are treated as unknown rather than fatal.

UA classes: `app` is the IMDb app, `safari` is MobileSafari, `curl` is a probe,
`other` is anything else. Lines from before the status field existed show `-`.
"""
import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LOG = os.path.join(HERE, "requests.jsonl")


def ua_class(ua):
    ua = ua or ""
    if "IMDb/" in ua:
        return "app"
    if "Safari" in ua:
        return "safari"
    if ua.startswith("curl"):
        return "curl"
    return "other"


def load(path):
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                sys.stderr.write("skipping unparseable line %d\n" % lineno)
    return rows


def host_of(row):
    return (row.get("hostname") or row.get("host") or "?").split(":")[0]


def path_of(row):
    return row.get("raw_path") or row.get("path") or "?"


def statuses(rows):
    counts = collections.Counter(
        "-" if row.get("status") is None else str(row["status"]) for row in rows
    )
    return ", ".join("%s x%d" % (s, n) for s, n in sorted(counts.items()))


def total_bytes(rows):
    return sum(int(row.get("bytes") or 0) for row in rows)


def print_timeline(rows, width=34):
    for row in rows:
        print("  %s  %-5s %-*s %-8s %s" % (
            row.get("ts", "?"),
            row.get("method", "GET"),
            width, host_of(row),
            ("%sB" % row["bytes"]) if row.get("bytes") is not None else "-",
            path_of(row) + (" [proxied]" if row.get("proxied") else ""),
        ))


def main():
    ap = argparse.ArgumentParser(description="Summarize the shim request log.")
    ap.add_argument("log", nargs="?", default=DEFAULT_LOG)
    ap.add_argument("--app-only", action="store_true", help="only IMDb app requests")
    ap.add_argument("--timeline", action="store_true", help="chronological, no grouping")
    ap.add_argument("--errors", action="store_true", help="only non-2xx responses")
    args = ap.parse_args()

    if not os.path.exists(args.log):
        sys.stderr.write("no such log: %s\n" % args.log)
        return 1

    rows = load(args.log)
    if args.app_only:
        rows = [r for r in rows if ua_class(r.get("ua")) == "app"]
    if args.errors:
        rows = [r for r in rows if r.get("status") is not None and int(r["status"]) >= 300]

    print("%s: %d request(s)" % (args.log, len(rows)))
    if not rows:
        print("nothing to summarize — is the shim still running on :80?")
        return 0

    by_ua = collections.Counter(ua_class(r.get("ua")) for r in rows)
    print("by client: " + ", ".join("%s=%d" % kv for kv in sorted(by_ua.items())))

    if args.timeline:
        print()
        print_timeline(rows)
        return 0

    print("\nBY HOST")
    hosts = collections.OrderedDict()
    for row in rows:
        hosts.setdefault(host_of(row), []).append(row)
    for host, rs in sorted(hosts.items(), key=lambda kv: -len(kv[1])):
        print("  %4d  %-34s %8dB  %s" % (len(rs), host, total_bytes(rs), statuses(rs)))

    print("\nBY HOST + PATH")
    groups = collections.OrderedDict()
    for row in rows:
        groups.setdefault((host_of(row), path_of(row)), []).append(row)
    for (host, path), rs in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        rs.sort(key=lambda r: r.get("ts", ""))
        print("  %4d  %s%s" % (len(rs), host, path))
        print("        status: %-22s bytes: %-8d proxied: %s  clients: %s" % (
            statuses(rs), total_bytes(rs),
            "yes" if any(r.get("proxied") for r in rs) else "no",
            ", ".join(sorted({ua_class(r.get("ua")) for r in rs})),
        ))
        if len(rs) == 1:
            print("        seen: %s" % rs[0].get("ts", "?"))
        else:
            print("        seen: %s .. %s" % (rs[0].get("ts", "?"), rs[-1].get("ts", "?")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
