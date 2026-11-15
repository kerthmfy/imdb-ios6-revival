#!/usr/bin/env python3
"""Group captured traffic into unique endpoint templates with status codes.

Usage: python3 summarize.py [traffic.jsonl]
"""

import json
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "traffic.jsonl")


def template(path: str) -> str:
    p = re.sub(r"tt\d{5,}", "tt<ID>", path)
    p = re.sub(r"nm\d{5,}", "nm<ID>", p)
    p = re.sub(r"(?<=[=/])\d{3,}", "<N>", p)
    p = re.sub(r"\?.*$", "?<QUERY>", p)
    return p


def main() -> int:
    if not os.path.exists(PATH):
        print(f"no capture file at {PATH} — run ./run-capture.sh first")
        return 1

    reqs = {}
    rows = defaultdict(lambda: {"status": set(), "count": 0, "sample": ""})

    with open(PATH, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("kind") == "request":
                reqs[rec.get("id")] = rec
                continue
            if rec.get("kind") not in ("response", "error"):
                continue
            req = reqs.get(rec.get("id"), {})
            host = rec.get("host") or req.get("host") or "?"
            tpl = template(rec.get("path") or req.get("path") or "/")
            key = f"{host}{tpl}"
            row = rows[key]
            row["count"] += 1
            row["status"].add(
                rec.get("status") if rec.get("kind") == "response" else "ERR"
            )
            if not row["sample"]:
                row["sample"] = (req.get("path") or "")[:110]

    if not rows:
        print("capture file is empty — no requests recorded")
        return 1

    print(f"{'count':>5}  {'status':<12} endpoint")
    print("-" * 100)
    for key in sorted(rows, key=lambda k: (-rows[k]["count"], k)):
        row = rows[key]
        status = ",".join(str(s) for s in sorted(row["status"], key=str))
        print(f"{row['count']:>5}  {status:<12} {key}")

    hosts = sorted({k.split("/")[0] for k in rows})
    print()
    print("hosts seen:", ", ".join(hosts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
