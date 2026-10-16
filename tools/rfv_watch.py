# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Watch a running ReaperForVisual engine through REAPER's web interface, as the page does.

    python tools/rfv_watch.py [--seconds 20] [--port 2307]

Polls the frame ten times a second (and the graph whenever its version changes) and prints
what a page would see: frames per second, missed frames, request time, frame and graph size,
and the engine's own cost and tick pacing. Standard library only.
"""

from __future__ import annotations

import argparse
import http.client
import json
import statistics
import sys
import time


SECTION = "ReaperForVisual"


def get(conn: http.client.HTTPConnection, key: str) -> tuple[dict | None, float, int]:
    t0 = time.perf_counter()
    conn.request("GET", f"/_/GET/EXTSTATE/{SECTION}/{key}")
    body = conn.getresponse().read().decode("utf-8")
    ms = (time.perf_counter() - t0) * 1000
    parts = body.rstrip("\n").split("\t", 3)
    raw = parts[3] if len(parts) == 4 else ""
    out, i = [], 0
    while i < len(raw):  # undo the web interface's escaping of \\, \n and \t
        if raw[i] == "\\" and i + 1 < len(raw) and raw[i + 1] in "\\nt":
            out.append({"\\": "\\", "n": "\n", "t": "\t"}[raw[i + 1]]); i += 2
        else:
            out.append(raw[i]); i += 1
    raw = "".join(out)
    return (json.loads(raw) if raw else None), ms, len(body)


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--port", type=int, default=2307)
    ap.add_argument("--section", default="ReaperForVisual", help="ReaperForVisual_test for an engine started by a test")
    a = ap.parse_args()
    global SECTION
    SECTION = a.section
    conn = http.client.HTTPConnection("127.0.0.1", a.port, timeout=5)
    seqs, lat, sizes, gsizes, costs, gseq = [], [], [], [], [], None
    states = set()
    end = time.perf_counter() + a.seconds
    while time.perf_counter() < end:
        t0 = time.perf_counter()
        f, ms, n = get(conn, "frame")
        if f:
            seqs.append(f["seq"]); lat.append(ms); sizes.append(n); states.add(f["state"])
            if f.get("cost"): costs.append(f["cost"])
            if f["gseq"] != gseq:
                g, gms, gn = get(conn, "graph")
                gseq = f["gseq"]; gsizes.append((gn, gms, len(g["tracks"]) if g else 0))
        time.sleep(max(0, 0.1 - (time.perf_counter() - t0)))
    if not seqs:
        print("no frames: is the engine running?")
        return 1
    distinct = sorted(set(seqs))
    span = distinct[-1] - distinct[0] + 1
    lat.sort()
    print(f"frames seen {len(distinct)} of {span} published ({100 * len(distinct) / span:.0f} %) in {a.seconds:.0f} s; states {sorted(states)}")
    print(f"request: median {statistics.median(lat):.1f} ms, p95 {lat[int(len(lat) * .95)]:.1f}, max {lat[-1]:.1f}; frame {max(sizes) / 1024:.1f} KB")
    for gn, gms, nt in gsizes:
        print(f"graph: {nt} tracks, {gn / 1024:.1f} KB, {gms:.0f} ms")
    if costs:
        c = costs[-1]
        print("engine (last second): " + ", ".join(f"{k} {v}" for k, v in c.items()))
        worst = max(costs, key=lambda c: c.get("gap_ms_max", 0))
        print(f"worst tick gap seen: {worst.get('gap_ms_max')} ms (p95 {worst.get('gap_ms_p95')} ms); worst tick {max(c['ms_max'] for c in costs)} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
