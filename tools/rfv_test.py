# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Run ReaperForVisual Lua tests in a temporary REAPER tab.

    python tools/rfv_test.py tests/smoke_test.lua [more tests...] [--timeout 60]

Each test runs through tests/harness.lua, which opens a temporary project tab, runs the
test there, closes the tab without a save prompt and selects the user's tab again.
Development only: it talks to REAPER through the Lua file bridge of the ReaperSkillsForClaude
plugin (claude_bridge.lua must be running). Set RFV_BRIDGE to point at its bridge.py.
Exit code 0 when every test prints PASS.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEB_URL = "http://127.0.0.1:{port}/rfv/index.html"


def find_bridge() -> Path:
    env = os.environ.get("RFV_BRIDGE")
    if env:
        return Path(env)
    root = Path.home() / ".claude" / "plugins" / "cache" / "reaper-skills-for-claude" / "reaper-for-claude"
    found = sorted(root.glob("*/scripts/bridge.py"),
                   key=lambda p: [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", p.parent.parent.name)])
    if not found:
        raise SystemExit(f"bridge.py not found under {root}; set RFV_BRIDGE")
    return found[-1]


def bridge(code: str, timeout: float) -> tuple[int, str]:
    r = subprocess.run([sys.executable, str(find_bridge()), "--code", code, "--timeout", str(timeout), "--quiet"],
                       capture_output=True, text=True, encoding="utf-8")
    return r.returncode, (r.stdout + r.stderr).strip()


def lua_str(path: Path) -> str:
    s = path.resolve().as_posix()
    if "]]" in s:
        raise SystemExit(f"path not usable in a Lua long string: {s}")
    return f"[[{s}]]"


def lua_str_raw(s: str) -> str:
    if "]]" in s:
        raise SystemExit(f"value not usable in a Lua long string: {s}")
    return f"[[{s}]]"


def check_web(port: int) -> str:
    try:
        with urllib.request.urlopen(WEB_URL.format(port=port), timeout=5) as r:
            body = r.read().decode("utf-8", "replace")
        ok = "ReaperForVisual" in body
        return f"web: {'OK' if ok else 'unexpected page'} ({r.status}, {len(body)} bytes) {WEB_URL.format(port=port)}"
    except Exception as e:  # noqa: BLE001 - report any failure as text
        return f"web: FAILED {WEB_URL.format(port=port)}: {e}"


def main() -> int:
    # Test output carries accented paths and dashes; a cp1252 console would crash on them.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="+", type=Path)
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--port", type=int, default=int(os.environ.get("RFV_WEB_PORT", "2307")))
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="passed to the tests as _G.RFV_ARGS[KEY] = VALUE (strings)")
    a = ap.parse_args()
    args = dict(kv.split("=", 1) for kv in a.set)

    code, out = bridge("return reaper.GetAppVersion()", 5)
    if code != 0 or not out:
        print(f"REAPER bridge not answering: {out}")
        return 2
    print(f"REAPER {out}")
    print(check_web(a.port))

    # spaces matter: "[[[" would open a Lua long string
    lua_args = ", ".join(f"[ {lua_str_raw(k)} ] = {lua_str_raw(v)}" for k, v in args.items())
    code, out = bridge(f"_G.RFV_ARGS = {{{lua_args}}} return 'args'", 5)
    if code != 0 or out != "args":
        print(f"could not pass --set values: {out}")
        return 2

    failed = 0
    h = f"dofile({lua_str(REPO / 'tests' / 'harness.lua')})"
    for t in a.tests:
        code, out = bridge(f"return {h}.begin({lua_str(t)})", a.timeout)
        if code != 0 or not out.startswith("BEGIN"):
            print(out)
            failed += 1
            continue
        while True:
            code, out = bridge(f"return {h}.step()", a.timeout)
            if code != 0 or not out.startswith("STEP"):
                break
            wait = float(out.split("wait=", 1)[1]) if "wait=" in out else 0
            if wait > 0:
                time.sleep(wait)
        code, out = bridge(f"return {h}.finish()", a.timeout)
        print(out)
        if code != 0 or not out.startswith("PASS"):
            failed += 1
    print(f"{len(a.tests) - failed}/{len(a.tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
