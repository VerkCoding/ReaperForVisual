# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Reference for the engine's meter pipeline (roadmap step 5), on rendered stems.

    venv/python tools/meter_reference.py [--fit] [--set band] [--hoangda DIR]

REAPER's track meter is emulated as measured (2026-10-11): it refreshes every REFRESH s and,
between peaks, falls one fixed STEP_DB per refresh (30 dB/s with vudecay = 30). The engine reads
it every TICK s, so it sees each refresh once or twice. The pipeline below is what
engine/rfv_meter.lua does, step by step, so the two can be compared on the same input:

  1. a reading equal to the previous one is the same refresh, unless it has stood for longer than
     REPEAT_GAP: then the peak repeated and it counts with the previous reading's status
  2. the meter shows max(peak, decay line), the line falling about one step per refresh (the
     refresh wobbles, so a step is 1.38 to 1.41 dB live): per channel, a reading that fell by at
     least STEP_MIN steps is "on the line", so CENS x reading is used; a smaller fall or a rise
     is the exact peak of that refresh; a reading under FLOOR is silence
  3. per refresh: power PL, PR (squares); a reading on the line between two exact readings,
     with the next one back up, is a refresh without audio and is dropped from the time the
     next reading arrives
  4. X over the last X_WIN s: tangent law on the summed PL, PR
  5. Z over the last Z_WIN s: 10 log10(mean S) - (CREST_A + CREST_B * 10 log10(max S / mean S)),
     S = PL + PR; no exact reading in the window means silence (no Z, no X). Of the cheap crest
     features tried (mean or median jump, share of readings on the decay line, mean/median,
     max/mean, and pairs of them), max/mean alone did best: 1.46 dB median, p90 3.17, against
     1.63 / 4.20 for the mean jump (2 s windows, leave-one-track-out on the band fixture).

--fit fits CREST_A and CREST_B on the band fixture (leave-one-track-out) and prints them.
Judged against the stems' exact power over the same windows and against truth.json per section.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path

import numpy as np
import soundfile as sf

REFRESH, TICK, STEP_DB = 0.04716, 0.03125, 1.4148   # measured 2026-10-11: 1.4148 dB per refresh, 30 dB/s
CENS = 0.4
STEP_MIN, REPEAT_GAP, FLOOR = 0.95, 0.055, 1e-5
X_WIN, Z_WIN = 0.5, 2.0
MODEL = "held"                        # how the meter is emulated (emulate_reads, --model)
CREST_A, CREST_B = 4.480, 0.467       # fitted on REAPER's own readings of the band fixture (--live-reads); the emulation gave 4.546, 0.502
T30 = math.tan(math.radians(30))
TRUTH = Path(os.environ.get("TEMP", "/tmp")) / "rfv-truth"


def az(pl: float, pr: float) -> float:
    l, r = math.sqrt(pl), math.sqrt(pr)
    return 0.0 if l + r <= 0 else math.degrees(math.atan((r - l) / (l + r) * T30))


def emulate_reads(x: np.ndarray, sr: int, jitter: float = 0.003, seed: int = 1, model: str | None = None):
    """What the engine reads: (time, L, R) at every tick.

    model "live" (measured 2026-10-12): the audio thread raises the meter at once whenever audio
    peaks above it, and REAPER's UI lowers it one step at its meter ticks (every REFRESH), unless
    a peak since the last tick holds it up. Inside one blocking script call the meter rose twice
    on noise and never fell on a decaying tone. So a read between two ticks shows the value of
    the last tick or any higher peak since then.
    model "held" (the default): the meter changes only at its ticks. It misses the rises between
    ticks, yet its Z statistics are the closer ones: crest coefficients fitted on it (4.546,
    0.502) sit near those fitted on REAPER's own readings (4.480, 0.467), while the "live" model
    gives 5.02, 0.56, which misjudged recordings it never saw by 1.4 dB against 0.8."""
    model = model or MODEL
    n_ref = int(len(x) / sr / REFRESH)
    edges = (np.arange(n_ref + 1) * REFRESH * sr).astype(int)
    fall = 10 ** (-STEP_DB / 20)
    a = np.abs(x[:, :2])
    m = np.zeros((n_ref, 2))
    e = np.zeros(2)
    for k in range(n_ref):
        seg = a[edges[k]:edges[k + 1]]
        pk = seg.max(axis=0) if len(seg) else np.zeros(2)
        e = np.maximum(pk, e * fall)
        m[k] = e                      # the value at the tick that ends interval k
    rng = np.random.default_rng(seed)
    t, reads = 0.0, []
    end = n_ref * REFRESH
    while t < end:
        k = min(int(t / REFRESH), n_ref - 1)
        if model == "held":
            v = m[k]
        else:
            base = m[k - 1] if k > 0 else np.zeros(2)
            seg = a[edges[k]:max(edges[k] + 1, int(t * sr) + 1)]
            v = np.maximum(base, seg.max(axis=0)) if len(seg) else base
        reads.append((t, float(v[0]), float(v[1])))
        t += TICK + rng.uniform(-jitter, jitter)
    return reads


def pipeline(reads):
    """Per refresh: (time, PL, PR, jump, exact). Steps 1-3 of the docstring."""
    out, prev, prev_s, prev_t, prev_cens = [], None, None, -1.0, (False, False)
    last_ex = last_c = before_ex = False
    last_ds = 0.0
    for t, l, r in reads:
        repeat = prev is not None and l == prev[0] and r == prev[1]
        if repeat and ((l == 0 and r == 0) or t - prev_t < REPEAT_GAP):
            continue
        raw, cens = [], []
        exact = False
        for c, v in enumerate((l, r)):
            p = prev[c] if prev is not None else 0.0
            if repeat and prev_cens[c]:
                raw.append(0.0 if v < FLOOR else CENS * v)
                cens.append(True)
                continue
            if not repeat and v > 0 and p > 0 and v < p:
                if 20 * math.log10(p / v) >= STEP_MIN * STEP_DB:
                    raw.append(0.0 if v < FLOOR else CENS * v)
                    cens.append(True)
                    continue
            raw.append(0.0 if v < FLOOR else v)
            cens.append(False)
            if v >= FLOOR: exact = True
        pl, pr = raw[0] ** 2, raw[1] ** 2
        s = math.sqrt(pl + pr)
        jump = abs(20 * math.log10(s / prev_s)) if prev_s and s > 0 else 0.0
        ds = l * l + r * r
        if exact and last_c and before_ex and ds >= last_ds and out:
            out[-1][5] = t          # the last reading was a refresh without audio
        out.append([t, pl, pr, jump, exact, math.inf])
        before_ex, last_ex, last_c, last_ds = last_ex, exact, (not exact) and any(cens), ds
        prev, prev_s, prev_t, prev_cens = (l, r), (s if s > 0 else prev_s), t, tuple(cens)
    return out


def windows(refs, t, win, times=None):
    """refs with t - win < time <= t (refs are in time order)"""
    import bisect
    times = times if times is not None else [x[0] for x in refs]
    return refs[bisect.bisect_right(times, t - win):bisect.bisect_right(times, t)]


def estimate(refs, t, a=None, b=None, times=None):
    """X and Z at time t (steps 4-5), or (None, None) when silent."""
    a = CREST_A if a is None else a
    b = CREST_B if b is None else b
    zw = [x for x in windows(refs, t, Z_WIN, times) if x[5] > t]
    if not any(x[4] for x in zw):
        return None, None, None
    s = [x[1] + x[2] for x in zw]
    p = sum(s) / len(s)
    feat = 10 * math.log10(max(s) / p) if p > 0 else 0.0
    xw = [x for x in windows(refs, t, X_WIN, times) if x[5] > t]
    xl, xr = sum(x[1] for x in xw), sum(x[2] for x in xw)
    return az(xl, xr) if xl + xr > 0 else None, 10 * math.log10(p) - (a + b * feat) if p > 0 else None, feat


def frames(x, sr, a=None, b=None, step=0.1):
    refs = pipeline(emulate_reads(x, sr))
    times = [r[0] for r in refs]
    out, i = [], 0
    t = Z_WIN
    end = len(x) / sr
    while t < end:
        X, Z, jump = estimate(refs, t, a, b, times)
        y = x[int((t - Z_WIN) * sr):int(t * sr), :2]
        out.append((t, X, Z, jump, float(np.mean(y[:, 0] ** 2) + np.mean(y[:, 1] ** 2)), float(np.mean(y[:, 0] ** 2)), float(np.mean(y[:, 1] ** 2))))
        t += step
    return out


def read_live(folder: Path):
    """Readings recorded by tests/meter_record_test.lua: times, play positions, and per track a list
    of (time, L, R) as the engine would have fed them."""
    rows = np.loadtxt(folder / "reads.csv", delimiter=",", ndmin=2)
    names = (folder / "tracks.txt").read_text(encoding="utf-8").splitlines()
    t, pos = rows[:, 0], rows[:, 1]
    tracks = [[(float(t[i]), float(rows[i, 2 + 2 * k]), float(rows[i, 3 + 2 * k])) for i in range(len(t))] for k in range((rows.shape[1] - 2) // 2)]
    return t, pos, tracks, names


def live_frames(reads, t, pos, a=None, b=None, step=0.1):
    """(pos, X, Z, feature) every `step` s of reading time, from REAPER's own readings."""
    refs = pipeline(reads)
    times = [r[0] for r in refs]
    out, tt = [], Z_WIN
    while tt <= t[-1]:
        X, Z, j = estimate(refs, tt, a, b, times)
        out.append((float(np.interp(tt, t, pos)), X, Z, j))
        tt += step
    return out


def window_power(x, sr, p0, p1):
    y = x[max(0, int(p0 * sr)):max(0, int(p1 * sr)), :2]
    return float(np.mean(y[:, 0] ** 2) + np.mean(y[:, 1] ** 2)) if len(y) else 0.0


def live_reads(folder: Path, a):
    t, pos, tracks, names = read_live(folder)
    print(f"{folder.name}: {len(t)} readings of {len(tracks)} tracks, tick median {1000 * np.median(np.diff(t)):.1f} ms")
    if a.files:
        # another source: exact power of the files over the same 2 s, and per 20 s section
        A_, B_ = CREST_A, CREST_B
        allw, alls = [], []
        for k, f in enumerate(a.files):
            info = sf.info(f)
            x, sr = sf.read(f, always_2d=True, dtype="float32", start=int(a.offset * info.samplerate),
                            frames=int((pos[-1] + 1) * info.samplerate))
            x = x.astype(np.float64)
            if x.shape[1] == 1: x = np.repeat(x, 2, axis=1)
            fr = live_frames(tracks[k], t, pos, 0.0, 0.0)
            ew, chunks = [], {}
            for (p, X, Z, j) in fr:
                c = int(p // 20)
                zc = None if Z is None else Z - (A_ + B_ * j)
                if p >= c * 20 + Z_WIN:
                    chunks.setdefault(c, []).append(10 ** (zc / 10) if zc is not None else 0.0)
                pw = window_power(x, sr, p - Z_WIN, p)
                if zc is not None and pw > 1e-7: ew.append(zc - 10 * math.log10(pw))
            es = []
            for c, pw in chunks.items():
                p = window_power(x, sr, c * 20, (c + 1) * 20)
                if p > 1e-7 and pw: es.append(10 * math.log10(max(np.mean(pw), 1e-20)) - 10 * math.log10(p))
            allw += ew; alls += es
            q = lambda e: f"median {np.median(np.abs(e)):.2f} p90 {np.percentile(np.abs(e), 90):.2f} bias {np.median(e):+.2f}" if e else "none"
            print(f"  {Path(f).name}: per 2 s window {q(ew)} (n={len(ew)}); per 20 s section {q(es)} (n={len(es)})")
        print(f"  all, crest {A_:.3f} + {B_:.3f} x feature: per window median {np.median(np.abs(allw)):.2f} p90 {np.percentile(np.abs(allw), 90):.2f} "
              f"bias {np.median(allw):+.2f}; per section median {np.median(np.abs(alls)):.2f} p90 {np.percentile(np.abs(alls), 90):.2f} bias {np.median(alls):+.2f} (n={len(alls)})")
        return
    # a fixture with truth: fit on REAPER's readings (leave one track out) and judge per section
    st, truth, secs = load(a.set)
    by_name = {tt["name"]: i for i, tt in enumerate(st["tracks"])}
    data = []
    for k, nm in enumerate(names):
        ti = by_name.get(nm)
        if ti is None: continue
        x, sr = sf.read(st["tracks"][ti]["stem"], always_2d=True)
        if x.shape[1] == 1: x = np.repeat(x, 2, axis=1)
        fr = live_frames(tracks[k], t, pos, 0.0, 0.0)
        data.append((ti, [(p, X, Z, j, window_power(x, sr, p - Z_WIN, p)) for (p, X, Z, j) in fr]))
    rows = [(ti, Z, j, 10 * math.log10(pw)) for ti, fr in data for (p, X, Z, j, pw) in fr if Z is not None and pw > 1e-7]
    R = np.array(rows)
    y = R[:, 1] - R[:, 3]
    loto = {}
    for ti in np.unique(R[:, 0]):
        m = R[:, 0] != ti
        loto[int(ti)], *_ = np.linalg.lstsq(np.column_stack([np.ones(m.sum()), R[m, 2]]), y[m], rcond=None)
    coef, *_ = np.linalg.lstsq(np.column_stack([np.ones(len(y)), R[:, 2]]), y, rcond=None)
    print(f"  fit on REAPER's readings ({len(y)} windows): CREST_A = {coef[0]:.3f}, CREST_B = {coef[1]:.3f}")

    def sections(coefs):
        es, exs = [], []
        for ti, fr in data:
            A_, B_ = coefs(ti)
            tt = truth["tracks"][ti]["own"]
            for sname, s0, s1 in secs:
                tv = tt.get(sname)
                if not tv or tv["level_db"] < -70: continue
                sel = [f for f in fr if s0 + Z_WIN <= f[0] < s1]
                if not sel: continue
                pw = [10 ** ((f[2] - (A_ + B_ * f[3])) / 10) if f[2] is not None else 0.0 for f in sel]
                es.append(10 * math.log10(max(np.mean(pw), 1e-20)) - tv["level_db"])
                L_ = R_ = 0.0
                for f in sel:
                    if f[1] is None or f[2] is None: continue
                    w = 10 ** ((f[2] - (A_ + B_ * f[3])) / 10)
                    q = math.tan(math.radians(f[1])) / T30
                    l, r = (1 - q) / 2, (1 + q) / 2
                    L_ += w * l * l / (l * l + r * r); R_ += w * r * r / (l * l + r * r)
                if L_ + R_ > 0: exs.append(az(L_, R_) - tv["az_deg"])
        e, ex = np.array(es), np.abs(np.array(exs))
        return (f"Z median {np.median(np.abs(e)):.2f} p90 {np.percentile(np.abs(e), 90):.2f} bias {np.median(e):+.2f} (n={len(e)}); "
                f"X median {np.median(ex):.2f} p90 {np.percentile(ex, 90):.2f} max {ex.max():.2f}")
    print(f"  per section, stored crest {CREST_A:.3f}/{CREST_B:.3f}: {sections(lambda ti: (CREST_A, CREST_B))}")
    print(f"  per section, fit on all tracks:        {sections(lambda ti: (coef[0], coef[1]))}")
    print(f"  per section, leave-one-track-out:      {sections(lambda ti: tuple(loto.get(ti, coef)))}")


def load(name):
    st = json.load(open(TRUTH / name / "structure.json"))
    truth = json.load(open(TRUTH / name / "truth.json"))
    secs = [("all", 0, st["length"])] + [(r["name"], r["start"], r["end"]) for r in st["regions"]]
    return st, truth, secs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fit", action="store_true")
    ap.add_argument("--set", default="band")
    ap.add_argument("--files", nargs="*", default=[], help="judge Z windows on other audio files (no truth.json needed)")
    ap.add_argument("--offset", type=float, default=0.0, help="with --files: start this many seconds in")
    ap.add_argument("--dump", default="", help="write readings and frames of a few stems here, for tests/meter_logic_test.lua")
    ap.add_argument("--seconds", type=float, default=0.0, help="with --files: read only this long")
    ap.add_argument("--judge", default="", help="frames.json from tests/axes_second_test.lua: live Z against the files")
    ap.add_argument("--model", default="held", choices=["live", "held"], help="how the meter is emulated (emulate_reads)")
    ap.add_argument("--crest", nargs=2, type=float, default=None, metavar=("A", "B"), help="use these crest coefficients instead of the stored ones")
    ap.add_argument("--live-reads", default="", help="a folder from tests/meter_record_test.lua: REAPER's own readings; "
                    "with --set (truth per section, and a leave-one-track-out fit) or --files/--offset (exact power per window)")
    a = ap.parse_args()
    global MODEL, CREST_A, CREST_B
    MODEL = a.model
    if a.crest:
        CREST_A, CREST_B = a.crest
    if a.live_reads:
        live_reads(Path(a.live_reads), a)
        return
    if a.judge:
        J = json.load(open(a.judge, encoding="utf-8"))
        off, secs = J["offset"], J["seconds"]
        frames_live = J["frames"]
        allw, alls = [], []
        for i, f in enumerate(J["files"]):
            info = sf.info(f)
            x, sr = sf.read(f, always_2d=True, dtype="float32", start=int(off * info.samplerate), frames=int(secs * info.samplerate))
            x = x.astype(np.float64)
            if x.shape[1] == 1: x = np.repeat(x, 2, axis=1)
            ref = {round(t, 1): Z for (t, X, Z, j, p, pl, pr) in frames(x, sr)}
            ew, ee, chunks = [], [], {}
            for fr in frames_live:
                pos = fr["pos"]
                v = fr["a"][i]
                c = int(pos // 20)
                if pos >= c * 20 + Z_WIN:
                    chunks.setdefault(c, []).append(10 ** (v[1] / 10) if v and v[1] is not None else 0.0)
                if pos < Z_WIN or not v or v[1] is None: continue
                y = x[int((pos - Z_WIN) * sr):int(pos * sr), :2]
                p = float(np.mean(y[:, 0] ** 2) + np.mean(y[:, 1] ** 2))
                if p <= 1e-7: continue
                ew.append(v[1] - 10 * math.log10(p))
                rz = ref.get(round(pos, 1))
                if rz is not None: ee.append(v[1] - rz)
            es = []
            for c, pw in chunks.items():
                y = x[int(c * 20 * sr):int((c + 1) * 20 * sr), :2]
                p = float(np.mean(y[:, 0] ** 2) + np.mean(y[:, 1] ** 2))
                if p > 1e-7 and pw: es.append(10 * math.log10(max(np.mean(pw), 1e-20)) - 10 * math.log10(p))
            allw += ew; alls += es
            q = lambda e: f"median {np.median(np.abs(e)):.2f}  p90 {np.percentile(np.abs(e), 90):.2f}" if e else "none"
            print(f"{Path(f).name}: live Z per 2 s window vs exact: {q(ew)} (n={len(ew)}); live vs emulation: {q(ee)}; per 20 s section: {q(es)} (n={len(es)})")
        print(f"all: per window median {np.median(np.abs(allw)):.2f} p90 {np.percentile(np.abs(allw), 90):.2f}; per section median {np.median(np.abs(alls)):.2f} p90 {np.percentile(np.abs(alls), 90):.2f} (n={len(alls)})")
        return
    if a.dump:
        out = Path(a.dump)
        out.mkdir(parents=True, exist_ok=True)
        cases = [("calib", 0), ("calib", 2), ("calib", 6), ("calib", 8), ("band", 0), ("band", 2), ("band", 18), ("band", 27), ("band", 36)]
        names = []
        for setname, ti in cases:
            st, _, _ = load(setname)
            t = st["tracks"][ti]
            x, sr = sf.read(t["stem"], always_2d=True)
            reads = emulate_reads(x[:, :2], sr)
            refs = pipeline(reads)
            times = [r[0] for r in refs]
            key = f"{setname}_{ti:02d}"
            nl = "\n"
            with open(out / f"{key}.reads.csv", "w") as f:
                for tt, l, r in reads:
                    f.write(f"{float(tt)!r},{float(l)!r},{float(r)!r}{nl}")   # numpy 2 would print np.float64(...)
            with open(out / f"{key}.frames.csv", "w") as f:
                tt = Z_WIN
                while tt < len(x) / sr:
                    X, Z, _ = estimate(refs, tt, None, None, times)
                    f.write(f"{float(tt)!r},{'' if X is None else repr(float(X))},{'' if Z is None else repr(float(Z))}{nl}")
                    tt += 0.1
            names.append(f"{key} {t['name']}")
        (out / "cases.txt").write_text(nl.join(names) + nl, encoding="utf-8")
        print(f"wrote {len(cases)} cases to {out}")
        return
    if a.files:
        ew = []
        for f in a.files:
            info = sf.info(f)
            x, sr = sf.read(f, always_2d=True, dtype="float32", start=int(a.offset * info.samplerate),
                            frames=int(a.seconds * info.samplerate) if a.seconds else -1)
            x = x.astype(np.float64)
            if x.shape[1] == 1: x = np.repeat(x, 2, axis=1)
            e = [Z - 10 * math.log10(p) for (_, X, Z, j, p, _, _) in frames(x, sr) if Z is not None and p > 1e-7]
            ew += e
            e = np.abs(np.array(e))
            print(f"{Path(f).name}: Z per {Z_WIN} s window vs exact power: median {np.median(e):.2f}  p90 {np.percentile(e, 90):.2f}  n={len(e)}")
        e = np.abs(np.array(ew))
        print(f"all files: median {np.median(e):.2f}  p90 {np.percentile(e, 90):.2f}  n={len(e)}")
        return
    st, truth, secs = load(a.set)
    data = []
    for ti, t in enumerate(st["tracks"]):
        x, sr = sf.read(t["stem"], always_2d=True)
        if x.shape[1] == 1: x = np.repeat(x, 2, axis=1)
        data.append((ti, frames(x, sr, 0.0, 0.0)))   # raw (uncorrected) Z, corrected below
    if a.fit:
        rows = [(ti, Z, j, 10 * math.log10(p)) for ti, fr in data for (_, X, Z, j, p, _, _) in fr if Z is not None and p > 1e-7]
        R = np.array(rows)
        y = R[:, 1] - R[:, 3]
        pred = np.zeros(len(y))
        for ti in np.unique(R[:, 0]):
            m = R[:, 0] != ti
            coef, *_ = np.linalg.lstsq(np.column_stack([np.ones(m.sum()), R[m, 2]]), y[m], rcond=None)
            pred[R[:, 0] == ti] = coef[0] + coef[1] * R[R[:, 0] == ti, 2]
        e = np.abs(y - pred)
        coef, *_ = np.linalg.lstsq(np.column_stack([np.ones(len(y)), R[:, 2]]), y, rcond=None)
        print(f"crest fit on {len(y)} windows of {Z_WIN} s: CREST_A = {coef[0]:.3f}, CREST_B = {coef[1]:.3f}; "
              f"leave-one-track-out window error median {np.median(e):.2f} dB, p90 {np.percentile(e, 90):.2f}")
        return
    # windows and sections with the stored coefficients
    ew, ex, es, exs = [], [], [], []
    for ti, fr in data:
        tt = truth["tracks"][ti]["own"]
        for (t, X, Z, j, p, pl, pr) in fr:
            if Z is None or p <= 1e-7: continue
            ew.append(Z - (CREST_A + CREST_B * j) - 10 * math.log10(p))
        for sname, s0, s1 in secs:
            tv = tt.get(sname)
            if not tv or tv["level_db"] < -70: continue
            sel = [f for f in fr if s0 + Z_WIN <= f[0] < s1]
            if not sel: continue
            pw = [10 ** ((f[2] - (CREST_A + CREST_B * f[3])) / 10) if f[2] is not None else 0.0 for f in sel]
            es.append(10 * math.log10(max(np.mean(pw), 1e-20)) - tv["level_db"])
            sl = sum(f[5] for f in sel if f[1] is not None)
            # X per section: the 0.5 s windows' powers summed, weighted by the estimated power
            xs = [(f[1], 10 ** ((f[2] - (CREST_A + CREST_B * f[3])) / 10)) for f in sel if f[1] is not None and f[2] is not None]
            if xs:
                # convert each window's azimuth back to a left/right split and add powers
                L = R_ = 0.0
                for xdeg, w in xs:
                    q = math.tan(math.radians(xdeg)) / T30            # (r-l)/(r+l) of amplitudes
                    l, r = (1 - q) / 2, (1 + q) / 2
                    L += w * l * l / (l * l + r * r); R_ += w * r * r / (l * l + r * r)
                exs.append(az(L, R_) - tv["az_deg"])
    def st_(e):
        e = np.abs(np.array(e)); return f"median {np.median(e):.2f}  p90 {np.percentile(e, 90):.2f}  max {e.max():.2f}  n={len(e)}"
    print(f"{a.set}: Z per {Z_WIN} s window vs exact power: {st_(ew)} dB")
    print(f"{a.set}: Z per section vs level_db: {st_(es)} dB")
    print(f"{a.set}: X per section vs az_deg: {st_(exs)} deg")


if __name__ == "__main__":
    main()
