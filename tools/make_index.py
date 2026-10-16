# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Write the ReaPack index (index.xml) for a release of ReaperForVisual.

    python tools/make_index.py --ref v0.1.0                            (a release, from git)
    python tools/make_index.py --base http://127.0.0.1:8765 --local    (a local test)

One package, "ReaperForVisual", in the index "VerkCoding" (ReaPack installs a script under
Scripts/<index>/<category>/; an index named after the tool would install into the folder a
development checkout links: DESIGN.md, step 11 research):
  - the actions (every "ReaperForVisual - *.lua"), registered in REAPER's Action List;
  - the engine's modules (engine/rfv_*.lua), beside them;
  - the page (web/, vendor included) as web interface files: ReaPack puts them under
    reaper_www_root/rfv/, where the engine opens the page.
A release reads every file from the git ref (the tag), so each file's SHA-256 is that of the
bytes GitHub serves (git stores LF; a Windows checkout has CRLF), and links to it at that ref.
--local serves the working tree as it is, without hashes. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
GITHUB = "VerkCoding/ReaperForVisual"
INDEX_NAME = "VerkCoding"
CATEGORY = "ReaperForVisual"
PACKAGE = "ReaperForVisual"
ABOUT = ("See where every part of your REAPER mix sits: left to right, low to high, near to far, "
         "live while it plays. A read-only script and a web page in your browser.")
# ReaPack's package list shows a package by its desc, not its name: the README tells users to
# right-click "ReaperForVisual" there (seen in a clean install, ReaPack 1.2.6).
DISPLAY = "ReaperForVisual"


def version_of() -> str:
    for line in (REPO / "engine" / "rfv_core.lua").read_text(encoding="utf-8").splitlines():
        if line.startswith("RFV.VERSION"):
            return line.split('"')[1]
    raise SystemExit("no RFV.VERSION in engine/rfv_core.lua")


def files() -> list[tuple[str, str, str]]:
    """(repository path, installed file, kind): kind is 'action', 'module' or 'web'."""
    out = []
    for p in sorted((REPO / "engine").glob("ReaperForVisual - *.lua")):
        out.append((f"engine/{p.name}", p.name, "action"))
    for p in sorted((REPO / "engine").glob("rfv_*.lua")):
        out.append((f"engine/{p.name}", p.name, "module"))
    for p in sorted((REPO / "web").rglob("*")):
        if p.is_file():
            rel = p.relative_to(REPO / "web").as_posix()
            out.append((f"web/{rel}", f"rfv/{rel}", "web"))
    return out


def git_bytes(ref: str, path: str) -> bytes:
    r = subprocess.run(["git", "-C", str(REPO), "show", f"{ref}:{path}"], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"{path} is not in {ref}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=GITHUB, help=f"GitHub USER/REPO the release is published from (default {GITHUB})")
    ap.add_argument("--ref", help="the git tag (or commit) of the release, e.g. v0.1.0")
    ap.add_argument("--base", help="base URL of the files instead of GitHub (with --local)")
    ap.add_argument("--local", action="store_true", help="link the working tree, no hashes (a local test)")
    ap.add_argument("--changelog", default="First release.", help="this version's changes")
    ap.add_argument("--out", default=str(REPO / "index.xml"))
    a = ap.parse_args()
    if a.local:
        if not a.base:
            raise SystemExit("--local needs --base")
        base = a.base.rstrip("/")
    else:
        if not a.ref:
            raise SystemExit("a release needs --ref TAG")
        base = f"https://raw.githubusercontent.com/{a.repo}/{a.ref}"
    version = version_of()
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    website = f"https://github.com/{a.repo}"

    sources = []
    for path, target, kind in files():
        url = f"{base}/{quote(path)}"
        attrs = [f'file="{escape(target, {chr(34): "&quot;"})}"']
        if kind == "action":
            attrs.append('main="main"')
        if kind == "web":
            attrs.append('type="webinterface"')
        if not a.local:
            attrs.append(f'hash="1220{hashlib.sha256(git_bytes(a.ref, path)).hexdigest()}"')
        sources.append(f'        <source {" ".join(attrs)}>{escape(url)}</source>')

    links = f'\n        <link rel="website">{escape(website)}</link>' if website else ""
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<index version="1" name="{INDEX_NAME}">
  <metadata>
    <description><![CDATA[ReaperForVisual and other REAPER tools by VerkCoding.]]></description>{links}
  </metadata>
  <category name="{CATEGORY}">
    <reapack name="{PACKAGE}" type="script" desc="{escape(DISPLAY)}">
      <metadata>
        <description><![CDATA[{ABOUT}]]></description>{links}
      </metadata>
      <version name="{version}" author="VerkCoding" time="{now}">
        <changelog><![CDATA[{a.changelog}]]></changelog>
{chr(10).join(sources)}
      </version>
    </reapack>
  </category>
</index>
"""
    Path(a.out).write_text(xml, encoding="utf-8", newline="\n")
    print(f"wrote {a.out}: {PACKAGE} {version}, {len(sources)} files, from {base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
