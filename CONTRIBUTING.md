# Contributing to ReaperForVisual

Thank you for helping. This page is for people who change the code; to use ReaperForVisual, see the [README](README.md).

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by:` line with your real name and e-mail. By adding it you state that you wrote the change, or have the right to submit it, under the project's licence: the [Developer Certificate of Origin 1.1](https://developercertificate.org/). Git adds the line for you:

```
git commit -s
```

Contributions are licensed under the GNU Affero General Public License v3.0 only, like the rest of the code; the `.rfv.json` format in `spec/` is MIT.

## How the code is laid out

- `engine/`: the Lua engine that runs inside REAPER (`rfv_engine.lua` and its modules) and the actions (`ReaperForVisual - *.lua`).
- `web/`: the page REAPER's web interface serves (`index.html`, `stage.js`; `debug.html` lists every track).
- `spec/`: the `.rfv.json` format.
- `tests/`: Lua tests that run inside REAPER, in a temporary project tab; `tests/fixtures/` builds the test projects.
- `tools/`: the test runner, the ground-truth renders and statistics, and the release index.
- [DESIGN.md](DESIGN.md): how it works and what was measured; [ROADMAP.md](ROADMAP.md): the steps and their gates.

Text in the repository is in English. Every source file starts with an `SPDX-License-Identifier` line and the copyright line.

## Running it from a checkout (Windows)

1. Turn on REAPER's web interface (see the README, step 4).
2. Link REAPER to the checkout once: `python tools/dev_link.py`. It creates the junctions `Scripts\ReaperForVisual` (to `engine/`) and `reaper_www_root\rfv` (to `web/`) in REAPER's resource folder, so an edit reaches REAPER without copying.
3. In REAPER: *Actions > Show action list > New action > Load ReaScript...*, open `Scripts\ReaperForVisual` and load the `ReaperForVisual - *.lua` files.

Do not install the ReaPack package on the same REAPER while the junctions are there: both would register the same actions.

## Tests

The tests drive REAPER through a Lua file bridge: `claude_bridge.lua` from the ReaperSkillsForClaude plugin must be running in REAPER, and `RFV_BRIDGE` can point at its `bridge.py`. Then:

```
python tools/rfv_test.py tests/<name>_test.lua [--set key=value] [--timeout seconds]
```

Each test opens a temporary project tab, closes it without saving and selects your tab again. The harness refuses to run while the active project plays.

- The whole suite: every `tests/*_test.lua` except `engine_load_test.lua`, `meter_record_test.lua` and `endurance_test.lua` (about 40 minutes).
- `engine_load_test.lua --set tracks=224` measures the engine's cost on a large project; `endurance_test.lua --set minutes=60` runs it for an hour.
- Test signals: `python tools/make_signals.py`. Ground truth for a fixture: `python tools/rfv_test.py tests/truth_build.lua --set fixture=band`, then `python tools/truth_stats.py %TEMP%/rfv-truth/band --check` (needs numpy, scipy and soundfile).
- Some tests use material that is not in the repository: the multitracks of the `band` and `sotw` fixtures (licensed for education only), a folder of real projects (`roles`, `snapshot`) and the files of `axes_second`. Copy `tests/local_paths.example.lua` to `tests/local_paths.lua` (git ignores it) and fill in what you have, or set REAPER's environment variables `RFV_MEDIA`, `RFV_MEDIA2`, `RFV_PROJECTS` and `RFV_SECOND`. Without them, `roles`, `snapshot` and `axes_second` skip those parts, and building the `band` or `sotw` fixture stops with a message that names what is missing.

Live tests never touch your own projects. A test that can raise one of REAPER's dialogs (a plugin's licence prompt, for example) would hold every script: fixtures use REAPER's own plugins only.

## Releasing

1. Set the version in `engine/rfv_core.lua` (`RFV.VERSION`), commit, tag it (`git tag v0.1.0`) and push the branch and the tag to GitHub.
2. Write the ReaPack index from the tag: `python tools/make_index.py --ref v0.1.0 --changelog "..."` (the repository is `VerkCoding/ReaperForVisual`; `--repo` names another). Every file is read from the tag, so its checksum matches what GitHub serves.
3. Commit `index.xml` on the main branch and push. Users add `https://raw.githubusercontent.com/VerkCoding/ReaperForVisual/main/index.xml` to ReaPack; *Synchronize packages* brings them the new version.

To try an index before publishing, on a REAPER that has never seen ReaperForVisual:

1. `python tools/make_index.py --base http://127.0.0.1:8765 --local --out index-local.xml`, then serve the checkout: `python -m http.server 8765 --bind 127.0.0.1`.
2. Make an empty folder with a `reaper.ini` that holds `[REAPER]`, `audioclosestop=1` and `audiocloseinactive=1` (so this REAPER takes the audio device only while it plays), and put ReaPack's file in its `UserPlugins` folder.
3. Start a second REAPER on that folder: `reaper.exe -newinst -cfgfile "<folder>\reaper.ini"`. Your own REAPER, its settings and its projects are not touched. A new folder scans every plugin first (*Cancel* stops it after the current file); ReaPack then shows its default repositories: untick them to download nothing else.
4. Follow the README from step 2 with `http://127.0.0.1:8765/index-local.xml`, on another port than your own web interface's. Quit that REAPER from its own *File* menu and delete the folder.
