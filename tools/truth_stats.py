# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Ground truth, analysis side: the true stage of every track from its rendered files.

    python tools/truth_stats.py <truth dir> [--check] [--keep-stems]

Reads <dir>/structure.json and the files written by tools/truth_export.lua and writes
<dir>/truth.json. For each track (by GUID) and each section (every region, plus "all"),
under "own" (the track's output) and, when rendered, "heard" (through its buses and the
master):

  pl, pr           mean power of left and right over the whole section
  level_db         10*log10(pl + pr), silence included
  level_active_db  the same over 400 ms blocks that pass a gate (absolute -70 dB, then
                   10 dB below the mean of those): the level while the part plays
  loudness_lufs    ITU-R BS.1770 integrated loudness of the section (K-weighted, gated);
                   None for sample rates other than 48 kHz
  az_deg           perceived azimuth, tangent law, speakers at +-30 deg, from sqrt(pl), sqrt(pr)
  az_p10, az_p90   10th and 90th percentile of the azimuth of the active blocks: how far a
                   moving part travels
  corr             left/right correlation
  centroid_hz      power-weighted mean of log2(frequency), 20 Hz-20 kHz (Welch, 2048-pt Hann)
  centroid_a_hz    the same with the power A-weighted, closer to perceived brightness

These definitions are the reference the engine is measured against; change them only with
DESIGN.md. --check compares calib and nest with arithmetic. Needs numpy, scipy, soundfile.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

T30 = math.tan(math.radians(30))
F_LO, F_HI = 20.0, 20000.0
NFFT = 2048
SILENT = 1e-12
BLOCK, HOP = 0.4, 0.1
# BS.1770 K-weighting at 48 kHz
KB1 = np.array([1.53512485958697, -2.69169618940638, 1.19839281085285]); KA1 = np.array([1.0, -1.69065929318241, 0.73248077421585])
KB2 = np.array([1.0, -2.0, 1.0]); KA2 = np.array([1.0, -1.99004745483398, 0.99007225036621])


def azimuth(pl: float, pr: float) -> float:
    al, ar = math.sqrt(max(pl, 0.0)), math.sqrt(max(pr, 0.0))
    if al + ar <= 0:
        return 0.0
    return math.degrees(math.atan(T30 * (ar - al) / (ar + al)))


def a_weight(f: np.ndarray) -> np.ndarray:
    f2 = f ** 2
    ra = (12194.0 ** 2 * f2 ** 2) / ((f2 + 20.6 ** 2) * np.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2)) * (f2 + 12194.0 ** 2))
    return ra ** 2  # power weighting


def centroids(x: np.ndarray, sr: int) -> tuple[float | None, float | None]:
    if len(x) < NFFT:
        return None, None
    f, pl = signal.welch(x[:, 0], sr, window="hann", nperseg=NFFT)
    _, pr = signal.welch(x[:, 1], sr, window="hann", nperseg=NFFT)
    band = (f >= F_LO) & (f <= F_HI)
    out = []
    for w in ((pl + pr)[band], ((pl + pr) * a_weight(f))[band]):
        out.append(float(2 ** (np.sum(w * np.log2(f[band])) / w.sum())) if w.sum() > 0 else None)
    return out[0], out[1]


def block_sums(sq: np.ndarray, sr: int) -> np.ndarray:
    """Mean of sq over 400 ms windows every 100 ms (sq: samples x channels)."""
    n, hop = int(BLOCK * sr), int(HOP * sr)
    if len(sq) < n:
        return np.empty((0, sq.shape[1]))
    cs = np.vstack([np.zeros((1, sq.shape[1])), np.cumsum(sq, axis=0)])
    starts = np.arange(0, len(sq) - n + 1, hop)
    return (cs[starts + n] - cs[starts]) / n


def gated(p: np.ndarray, floor: float) -> np.ndarray:
    """BS.1770-style gate on block powers p: absolute floor, then 10 dB under their mean."""
    a = p[p > floor]
    if len(a) == 0:
        return np.zeros(len(p), dtype=bool)
    return (p > floor) & (p > a.mean() * 0.1)


def section_stats(x: np.ndarray, sr: int) -> dict | None:
    pl, pr = float(np.mean(x[:, 0] ** 2)), float(np.mean(x[:, 1] ** 2))
    if pl + pr < SILENT:
        return None
    c = float(np.mean(x[:, 0] * x[:, 1]))
    corr = c / math.sqrt(pl * pr) if pl > 0 and pr > 0 else (1.0 if pl > 0 or pr > 0 else 0.0)
    blocks = block_sums(x ** 2, sr)                       # per block: mean power of L, R
    pb = blocks.sum(axis=1)
    keep = gated(pb, 1e-7)                                  # -70 dB
    active = 10 * math.log10(pb[keep].mean()) if keep.any() else None
    azs = np.array([azimuth(l, r) for l, r in blocks[keep]]) if keep.any() else np.array([])
    lufs = None
    if sr == 48000:
        k = signal.lfilter(KB2, KA2, signal.lfilter(KB1, KA1, x, axis=0), axis=0)
        zk = block_sums(k ** 2, sr).sum(axis=1)
        kk = gated(zk, 10 ** ((-70 + 0.691) / 10))          # -70 LUFS
        lufs = -0.691 + 10 * math.log10(zk[kk].mean()) if kk.any() else None
    cen, cen_a = centroids(x, sr)
    return {"pl": pl, "pr": pr, "level_db": 10 * math.log10(pl + pr), "level_active_db": active, "loudness_lufs": lufs,
            "az_deg": azimuth(pl, pr), "az_p10": float(np.percentile(azs, 10)) if len(azs) else None,
            "az_p90": float(np.percentile(azs, 90)) if len(azs) else None,
            "corr": corr, "centroid_hz": cen, "centroid_a_hz": cen_a}


def analyse(path: str, sections: list) -> dict:
    x, sr = sf.read(path, dtype="float64", always_2d=True)
    if x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    res = {}
    for name, t0, t1 in sections:
        seg = x[int(t0 * sr):int(t1 * sr)]
        res[name] = section_stats(seg, sr) if len(seg) else None
    return res


# Arithmetic the rulers must reproduce. Keys: fixture -> layer -> track -> section -> field -> value.
# Tolerances: azimuth 0.05 deg, levels 0.05 dB, correlation 0.01, centroid 1.5 % (log2).
EXPECT = {
    "calib": {"own": {
        "sine pan +0.5": {"all": dict(az_deg=10.893, level_db=-14.08, level_active_db=-14.08)},
        "sine fader -6": {"all": dict(az_deg=0.0, level_db=-18.06)},
        "sine stereo -0.702 w0.3": {"all": dict(az_deg=-17.34, level_db=-14.68)},
        "st 500L 3kR": {"all": dict(az_deg=0.0, level_db=-12.04, corr=0.0, centroid_hz=1224.7)},
        "noise -20": {"all": dict(az_deg=0.0, level_db=-16.99, corr=1.0, centroid_hz=7408.5)},
        "st pan +0.5": {"all": dict(az_deg=10.893, level_db=-14.08, corr=0.0, centroid_hz=2096.7)},
        "noise anti-phase": {"all": dict(az_deg=0.0, level_db=-16.99, corr=-1.0)},
        "sine pan sweep": {"all": dict(az_deg=0.0, level_db=-13.80, az_p10=-21.05, az_p90=21.05),
                           "first half": dict(az_abs=8.80), "second half": dict(az_abs=8.80)},
    }},
    "nest": {"heard": {
        "a1 sine pan 0": {"all": dict(az_deg=-10.893, level_db=-14.08)},
        "a2 sine pan +0.5": {"all": dict(az_deg=0.0, level_db=-18.06)},
        "b1 st 500L 3kR": {"all": dict(az_deg=4.96, level_db=-15.67)},
        "b2 sine pan -1": {"all": dict(az_deg=-7.736, level_db=-19.24)},
        "c1 st 500L 3kR": {"all": dict(az_deg=0.0, level_db=-11.07)},
        "d1 sine": {"all": dict(az_deg=13.44, level_db=-15.04)},
        "d2 sine": {"all": dict(az_deg=0.0, level_db=-18.04)},
        "e1 sine": {"all": dict(az_deg=8.95, level_db=-16.92)},
    }, "own": {
        "a1 sine pan 0": {"all": dict(az_deg=0.0, level_db=-12.04)},
        "e1 sine": {"all": dict(az_deg=0.0, level_db=-12.04)},
    }},
}
TOL = dict(az_deg=0.05, az_abs=0.3, az_p10=1.0, az_p90=1.0, level_db=0.05, level_active_db=0.05, corr=0.01)


def check(fixture: str, out: dict) -> list[str]:
    exp = EXPECT.get(fixture)
    if not exp:
        return [f"no arithmetic for fixture '{fixture}'"]
    lines = []
    by = {t["name"]: t for t in out["tracks"]}
    for layer, tracks in exp.items():
        for name, secs in tracks.items():
            t = by.get(name)
            for sec, fields in secs.items():
                s = t and t.get(layer, {}).get(sec)
                for k, v in fields.items():
                    if not s:
                        lines.append(f"BAD {layer:5s} {name:24s} {sec:11s} missing")
                        continue
                    got = abs(s["az_deg"]) if k == "az_abs" else s[k]
                    if got is None:
                        ok = False
                    elif k == "centroid_hz":
                        ok = abs(math.log2(got / v)) < 0.015
                    else:
                        ok = abs(got - v) <= TOL[k]
                    lines.append(f"{'ok ' if ok else 'BAD'} {layer:5s} {name:24s} {sec:11s} {k:15s} expected {v:9.3f} got {got if got is None else round(got, 3)}")
    return lines


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", type=Path)
    ap.add_argument("--check", "--check-calib", action="store_true", help="compare with arithmetic (calib, nest)")
    ap.add_argument("--keep-stems", action="store_true", help="by default the rendered files are deleted after analysis")
    a = ap.parse_args()

    st = json.loads((a.dir / "structure.json").read_text(encoding="utf-8"))
    sections = [("all", 0.0, st["length"])] + [(r["name"], r["start"], r["end"]) for r in st["regions"]]
    out = {"project": st["project"], "srate": st["srate"], "sections": [s[0] for s in sections], "tracks": []}
    heard = any(t.get("heard") for t in st["tracks"])
    print(f"{'track':26s} {'own az / level / active':>26s}" + (f" {'heard az / level':>18s}" if heard else ""))
    for t in st["tracks"]:
        row = {"guid": t["guid"], "name": t["name"], "index": t["index"], "own": analyse(t["stem"], sections)}
        if t.get("heard"):
            row["heard"] = analyse(t["heard"], sections)
        out["tracks"].append(row)
        o = row["own"]["all"]
        cell = f"{o['az_deg']:+6.1f} {o['level_db']:6.1f} {o['level_active_db'] if o['level_active_db'] is None else round(o['level_active_db'], 1):>6}" if o else "-"
        h = row.get("heard", {}).get("all")
        hcell = f"{h['az_deg']:+6.1f} {h['level_db']:6.1f}" if h else ""
        print(f"{t['name'][:26]:26s} {cell:>26s} {hcell:>18s}")
    (a.dir / "truth.json").write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {a.dir / 'truth.json'}")
    rc = 0
    if a.check:
        lines = check(a.dir.name, out)
        print("\n".join(lines))
        rc = 1 if any(l.startswith("BAD") or l.startswith("no ") for l in lines) else 0
    if not a.keep_stems:
        for t in st["tracks"]:
            for p in (t.get("stem"), t.get("heard")):
                if p:
                    Path(p).unlink(missing_ok=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
