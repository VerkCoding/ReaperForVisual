# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Link REAPER's folders to this repository for development, or remove the links.

    python tools/dev_link.py            # create
    python tools/dev_link.py --status   # show
    python tools/dev_link.py --remove   # remove the links only; the repository is untouched

Links (Windows junctions):
    <REAPER resource>/Scripts/ReaperForVisual  -> engine/
    <REAPER resource>/reaper_www_root/rfv      -> web/
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def resource_dir() -> Path:
    env = os.environ.get("RFV_REAPER_RESOURCE")
    if env:
        return Path(env)
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "REAPER"
    raise SystemExit("Only Windows is supported for now; set RFV_REAPER_RESOURCE.")


def links() -> list[tuple[Path, Path]]:
    r = resource_dir()
    return [(r / "Scripts" / "ReaperForVisual", REPO / "engine"),
            (r / "reaper_www_root" / "rfv", REPO / "web")]


def is_link(p: Path) -> bool:
    return p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction())


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--remove", action="store_true")
    g.add_argument("--status", action="store_true")
    a = ap.parse_args()
    rc = 0
    for link, target in links():
        if a.status:
            state = f"-> {os.path.realpath(link)}" if is_link(link) else ("exists, NOT a link" if link.exists() else "absent")
            print(f"{link}: {state}")
        elif a.remove:
            if is_link(link):
                os.rmdir(link)  # removes the junction itself, never the target's files
                print(f"removed {link}")
            elif link.exists():
                print(f"left alone, not a link: {link}")
                rc = 1
        else:
            if is_link(link):
                print(f"already linked: {link} -> {os.path.realpath(link)}")
                continue
            if link.exists():
                print(f"refusing: {link} exists and is not a link")
                rc = 1
                continue
            link.parent.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True, text=True)
            print((r.stdout + r.stderr).strip())
            rc |= r.returncode
    return rc


if __name__ == "__main__":
    sys.exit(main())
