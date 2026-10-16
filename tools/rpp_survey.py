# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Survey the routing styles of REAPER projects by reading .rpp files as text.

    python tools/rpp_survey.py <project.rpp or folder> [...] [--tracks]

Nothing is opened in REAPER and no plugin is loaded. For each project it counts what the
role classifier (roadmap step 4) has to handle: folders, sends, sidechain and MIDI-only
sends, tracks with the master/parent send off, multichannel tracks, virtual instruments
(and those that feed other tracks from extra outputs), hardware outputs, live inputs.
--tracks prints one line per track. Standard library only.
"""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


def tokens(line: str) -> list[str]:
    try:
        return shlex.split(line, posix=True)
    except ValueError:
        return line.split()


def parse(path: Path) -> list[dict]:
    tracks, cur, depth, stack = [], None, 0, []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("<"):
            tag = line[1:].split(" ", 1)[0]
            stack.append(tag)
            if tag == "TRACK":
                cur = {"name": "", "isbus": (0, 0), "mainsend": 1, "poffs": 0, "nchan": 2, "recv": [], "hwout": 0,
                       "instr": [], "fx": 0, "items_audio": 0, "items_midi": 0, "rec": None, "mute": 0}
                tracks.append(cur)
            elif cur is not None and tag in ("VST", "CLAP", "JS", "DX", "AU", "LV2") and "FXCHAIN" in stack:
                cur["fx"] += 1
                head = line[1:]
                if re.search(r'"(VSTi|VST3i|CLAPi|AUi|LV2i|DXi)\s*:', head):
                    cur["instr"].append(re.sub(r'^\S+\s+"([^"]*)".*$', r"\1", head))
            elif cur is not None and tag == "SOURCE" and "ITEM" in stack:
                kind = line.split(" ", 1)[1] if " " in line else ""
                if kind.startswith("MIDI"):
                    cur["items_midi"] += 1
                elif kind.split(" ")[0] not in ("SECTION", "EMPTY", "VIDEO", "CLICK"):
                    cur["items_audio"] += 1
            continue
        if line.startswith(">"):
            if stack:
                tag = stack.pop()
                if tag == "TRACK":
                    cur = None
            continue
        if cur is None or not stack or stack[-1] != "TRACK":  # tracks sit inside <REAPER_PROJECT>
            continue
        t = tokens(line)
        if not t:
            continue
        k = t[0]
        if k == "NAME":
            cur["name"] = t[1] if len(t) > 1 else ""
        elif k == "ISBUS":
            cur["isbus"] = (int(t[1]), int(t[2]))
        elif k == "MAINSEND":
            cur["mainsend"], cur["poffs"] = int(t[1]), int(t[2]) if len(t) > 2 else 0
        elif k == "NCHAN":
            cur["nchan"] = int(t[1])
        elif k == "AUXRECV":
            # AUXRECV src mode vol pan mute mono phase srcchan dstchan ...
            cur["recv"].append({"src": int(t[1]), "mode": int(t[2]), "mute": int(t[5]), "srcchan": int(t[8]), "dstchan": int(t[9])})
        elif k == "HWOUT":
            cur["hwout"] += 1
        elif k == "REC":
            cur["rec"] = t[1:]
        elif k == "MUTESOLO":
            cur["mute"] = int(t[1])
    return tracks


def survey(path: Path, per_track: bool) -> dict:
    tr = parse(path)
    n = len(tr)
    sends = [(i, r) for i, t in enumerate(tr) for r in t["recv"]]
    midi_only = [x for x in sends if x[1]["srcchan"] < 0]
    side = [x for x in sends if x[1]["srcchan"] >= 0 and (x[1]["dstchan"] & 1023) >= 2]
    extra_out = [x for x in sends if x[1]["srcchan"] >= 0 and (x[1]["srcchan"] & 1023) >= 2]
    instr = [i for i, t in enumerate(tr) if t["instr"]]
    multi_out_instr = sorted({r["src"] for _, r in extra_out if 0 <= r["src"] < n and tr[r["src"]]["instr"]})
    out = {
        "tracks": n, "folders": sum(1 for t in tr if t["isbus"][0] == 1), "sends": len(sends),
        "midi_only_sends": len(midi_only), "sidechain_sends": len(side), "sends_from_extra_outputs": len(extra_out),
        "mainsend_off": sum(1 for t in tr if t["mainsend"] == 0), "parent_offset": sum(1 for t in tr if t["poffs"] > 0),
        "multichannel": sum(1 for t in tr if t["nchan"] > 2), "instrument_tracks": len(instr),
        "multi_out_instruments": len(multi_out_instr), "hw_outs": sum(1 for t in tr if t["hwout"]),
        "midi_item_tracks": sum(1 for t in tr if t["items_midi"]), "audio_item_tracks": sum(1 for t in tr if t["items_audio"]),
        "armed": sum(1 for t in tr if t["rec"] and t["rec"][0] == "1"), "muted": sum(1 for t in tr if t["mute"]),
    }
    if per_track:
        for i, t in enumerate(tr):
            rv = ",".join(f"{r['src']}:{r['srcchan']}->{r['dstchan']}{'M' if r['mute'] else ''}" for r in t["recv"])
            print(f"  {i:3d} {t['name'][:28]:28s} bus{t['isbus']} main={t['mainsend']}/{t['poffs']} ch={t['nchan']} "
                  f"a={t['items_audio']} m={t['items_midi']} fx={t['fx']}{' INSTR ' + t['instr'][0][:24] if t['instr'] else ''}"
                  f"{' recv[' + rv + ']' if rv else ''}{' hw' if t['hwout'] else ''}{' muted' if t['mute'] else ''}")
    return out


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    per = "--tracks" in sys.argv
    files: list[Path] = []
    for a in args:
        p = Path(a)
        files += sorted(x for x in p.rglob("*") if x.suffix.lower() == ".rpp" and "mcp-backup" not in x.name
                        and "Backups" not in x.parts) if p.is_dir() else [p]
    keys = None
    for f in files:
        if per:
            print(f"== {f}")
        s = survey(f, per)
        if keys is None:
            keys = list(s)
            print(f"{'project':48s} " + " ".join(f"{k[:9]:>9s}" for k in keys))
        print(f"{str(f.relative_to(f.anchor))[-48:]:48s} " + " ".join(f"{v:>9d}" for v in s.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
