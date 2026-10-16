# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Ground truth for a track's share of the mix: "heard" through buses whose FX are not linear.

    venv/python tools/truth_share.py <truth dir, e.g. %TEMP%/rfv-truth/band>

A track rendered alone through its buses (the "heard" layer) is exact for pan, fader and any
linear FX, but a bus compressor treats a track alone differently from the whole group: in the
band fixture, Room 3 alone came out 8 dB louder than its part in the mix. What a viewer of the
stage needs is the part in the mix. Defined here, from the rendered own stems, per W-second
window, bus by bus up the main path:

    share of a child at a bus = its power at the bus input / the bus input's power
                                x the bus output's power

with the bus input taken as the sum of the children's own stems through the bus's pan matrix
(REAPER renders FX before fader and pan; a broadband share ignores how EQ treats each child).
Adds "share" (level_db, az_deg per section, X from the per-channel shares) to truth.json, for
folder children; tracks reached by sends are left out (no send stems).
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

W = 0.05
T30 = math.tan(math.radians(30))


def az(pl, pr):
    l, r = math.sqrt(max(pl, 0)), math.sqrt(max(pr, 0))
    return 0.0 if l + r == 0 else math.degrees(math.atan((r - l) / (l + r) * T30))


def law_gains(p, law_db):
    if law_db == -3:
        th = math.radians((p + 1) * 45)
        return math.cos(th), math.sin(th)
    if law_db == -6:
        return (1 - p) / 2, (1 + p) / 2
    return (1.0 if p <= 0 else 1 - p), (1.0 if p >= 0 else 1 + p)


def matrix(t):
    """REAPER's pan as measured in step 2: amplitude matrix [[LL, RL], [LR, RR]] with the fader."""
    mode, p, w = t["panmode"], t["pan"], t["width"]
    law = -3 if abs(t["panlaw"] - 0.7079) < 0.01 else -6 if abs(t["panlaw"] - 0.5012) < 0.01 else 0
    if mode == 6:
        lL, lR = law_gains(t["dualpan"][0], 0)
        rL, rR = law_gains(t["dualpan"][1], 0)
        M = np.array([[lL, rL], [lR, rR]])
    elif mode == 5:
        Wm = np.array([[(1 + w) / 2, (1 - w) / 2], [(1 - w) / 2, (1 + w) / 2]])
        P = np.array([[1 - p, 0], [p / 2, 1 - p / 2]]) if p >= 0 else np.array([[1 - abs(p) / 2, abs(p) / 2], [0, 1 - abs(p)]])
        M = P @ Wm
    else:
        gl, gr = law_gains(p, law)
        M = np.array([[gl, 0], [0, gr]])
    return M * t["vol"]


def main():
    d = Path(sys.argv[1])
    st = json.load(open(d / "structure.json"))
    truth = json.load(open(d / "truth.json"))
    sr = st.get("srate", 48000)
    tracks = st["tracks"]
    by = {t["guid"]: i for i, t in enumerate(tracks)}
    kids = {}
    for i, t in enumerate(tracks):
        if t["parent"]: kids.setdefault(by[t["parent"]], []).append(i)
    stems = {i: sf.read(t["stem"], always_2d=True)[0][:, :2] for i, t in enumerate(tracks)}
    n = min(len(x) for x in stems.values())
    hop = int(W * sr)
    nw = n // hop

    def wpow(x):   # per-window power per channel: (nw, 2)
        return (x[:nw * hop] ** 2).reshape(nw, hop, 2).mean(axis=1)

    # per bus and window: the output power over the pan-matrixed input power (the bus's FX gain)
    gain = {}
    for b, ks in kids.items():
        M = matrix(tracks[b])
        x = sum(stems[k] for k in ks)[:n] @ M.T
        pin, pout = wpow(x).sum(axis=1), wpow(stems[b][:n]).sum(axis=1)
        gain[b] = np.where(pin > 1e-12, pout / np.maximum(pin, 1e-12), 1.0)

    secs = [("all", 0, st["length"])] + [(r["name"], r["start"], r["end"]) for r in st["regions"]]
    done = 0
    for i, t in enumerate(tracks):
        if not t["parent"]:
            continue
        x = stems[i][:nw * hop]
        g = t["parent"]
        while g:   # through each bus: its pan matrix and fader, then its FX gain in that window
            b = by[g]
            x = (x @ matrix(tracks[b]).T) * np.repeat(np.sqrt(gain[b]), hop)[:, None]
            g = tracks[b]["parent"]
        pw = wpow(x)
        share = {}
        for name, a, e in secs:
            s = pw[int(a / W):int(e / W)]
            pl, pr = float(s[:, 0].mean()), float(s[:, 1].mean())
            if pl + pr > 0:
                share[name] = {"pl": pl, "pr": pr, "level_db": 10 * math.log10(pl + pr), "az_deg": az(pl, pr)}
        truth["tracks"][i]["share"] = share
        done += 1
    json.dump(truth, open(d / "truth.json", "w"), indent=1)
    print(f"share added for {done} tracks under {len(kids)} buses, {W * 1000:.0f} ms windows, into {d / 'truth.json'}")
    for i, t in enumerate(tracks):
        s = truth["tracks"][i].get("share", {}).get("all")
        h = (truth["tracks"][i].get("heard") or {}).get("all")
        o = truth["tracks"][i]["own"].get("all")
        if s and o:
            print(f"  {t['name'][:16]:16s} own {o['level_db']:6.1f}  alone through buses {h['level_db'] if h else float('nan'):6.1f}  share in the mix {s['level_db']:6.1f}")


if __name__ == "__main__":
    main()
