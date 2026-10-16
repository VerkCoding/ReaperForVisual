# ReaperForVisual: design record

Status: design agreed, nothing built yet. Started 2026-10-10.

ReaperForVisual shows the stereo stage of a REAPER mix in 3D while it plays: where each part sits left to right, how high it sits in frequency, and how far forward it is. It runs inside REAPER as a read-only Lua script with a web page as its screen. It needs no AI and no plugin, and it never changes the project.

## Goals

The owner's five goals, and how each is read:

| Goal | Meaning |
|---|---|
| Realtime | While playing, the stage updates 10 times a second. While stopped, it shows the stage at the edit cursor and marks what is measured and what is estimated. |
| Every listening angle | Every chosen part has a position and a width, reverb returns included; the camera orbits freely. |
| All three axes | X = perceived azimuth (±30° speakers, tangent law). Y = spectral centroid on a log scale, 40 Hz to 12 kHz. Z = level relative to the whole mix. |
| Accurate | Positions come from measurement, not from knob settings, and are checked against renders. |
| Not a plugin | No FX inserted, no project change. One Lua script and one web page. |

## Scope

- Windows first. Linux and macOS later, so keep paths and shell calls in one place.
- Stereo masters only. 5.1 and 7.1 would be a major update and are not planned.
- English user interface. Repository content in English.
- Desktop browser on the same machine. Phone viewing is not a goal.

## Architecture

```
REAPER (main thread)                               Browser
┌────────────────────────────────────┐           ┌──────────────────────────┐
│ rfv_engine.lua (defer loop, ~30 Hz)│  ExtState │ reaper_www_root/rfv/     │
│  - routing graph, roles            │ ────────► │  three.js stage          │
│  - meters L/R every cycle          │  /_/GET/  │  - tangent law, layout   │
│  - AudioAccessor, fixed budget     │  EXTSTATE │  - Z, crest correction   │
│  - view set from <project>.rfv.json│ ◄──────── │  - track checklist       │
└────────────────────────────────────┘  /_/SET/  └──────────────────────────┘
```

- The engine measures, and since step 5 also computes X and Z, because they need every meter refresh (~46 ms) and the page sees ten frames a second. The page does layout and drawing, so it can change without touching REAPER.
- Two ExtState keys: `graph` (names, colours, structure; resent only when the project structure changes) and `frame` (numbers only).
- Rejected alternatives: the page reading `/_/TRACK` directly (one combined meter, so no left/right); drawing in a REAPER `gfx` window (3D by hand on REAPER's UI thread); an external Python process (150–600 ms per call); JSFX, VST, CLAP or ReaImGui (plugins or extensions).

## Engine and page: the protocol (step 3)

The engine is `engine/rfv_engine.lua`, started by the action script `engine/ReaperForVisual - Start or stop.lua` (`ReaperForVisual.lua` until release 0.1). Running that action again stops it, and its toolbar button lights while it runs.

ExtState section `ReaperForVisual` by default, all keys non-persistent. The section is an option of `E.run`. Tests use `ReaperForVisual_test`, so they never stop or overwrite an engine the user is running (verified while one ran).

| Key | Written | Holds |
|---|---|---|
| `frame` | about 10 times a second | JSON: `seq`, `gseq` (current graph version), `t`, `up` (seconds since start), `state` ("running" or, at exit, "stopped" with `reason`), `play`, `pos`, `tabs` (tabs cached), `cost` (tick time median, p95 and max in ms, ticks per second, gap between ticks median, p95 and max in ms), `err` (last error or null); since step 5: `a` (each track's own `[X, Z]`, X in degrees with + to the right, Z in dB; `[null, Z]` with no image, `null` when silent), `h` (where each track is heard, same form), `ma` (the master's own), `md` (the meter decay as measured: `step`, `refresh_ms`, `decay`, `vudecay`, `measured`), `hi` (buses with an image gap), `ae` (tracks whose own X/Z are estimated: live inputs), `hb` (tracks heard via their bus); since the step-5 review: `solo` (1 while any track is soloed), `hm` (tracks that sound but are silenced on their way: a mute above them, or a solo elsewhere), `ha` (tracks heard through a send taken before the FX, so their heard values ignore those FX); since step 8: `mu` (tracks muted themselves, by the button or a Mute envelope: their meters fall silent), and since its review `oc` (the stage objects cut from the master now by a mute, their own or one above them, or a solo elsewhere, whether they sound or not; a display group when all its members are: the stage keeps them where they were last heard); since step 9a: `sm` (1 while stopped: `a`, `h`, `o` and `ma` then come from the files at the edit cursor with the FX gains learned while playing; 0 from the meters) and `ob` (per stage object while stopped, `[here, elsewhere, never]`: the shares of its level whose FX gains were measured at this place, learned elsewhere in the song, never heard; a part with no FX counts as measured here, being exact from its files); `mp` (since the step 9b review, while stopped: the share of the stage's power, by object, that the meters measured at this place, which is what the page's note calls measured); and `nl` (stage objects with no level while stopped: a virtual instrument with MIDI at the cursor never heard since the engine started); since step 6: `o` (the stage's objects, as listed in the graph's `stage`, heard: `[X, Z]` or null), `ack`, `ack_ok`, `ack_msg` (the last page command applied or refused, by its sequence number), `note_n`, `note` (what the last REAPER action did to the view, counted).; since step 7: `y` (per track `[Y Hz, correlation, share of its power with no Y, share past FX it cannot hear, share of the window read]`; since the step-8 review the share read of a bus or a return is that of what its inputs bring, by power, or null for a track not needed or with nothing to say), `oy` (the same per stage object), `ym` (the spectrum map: tracks needed, how much of the readout and of the whole song is read, since step 9a also `coarse` (the whole song with a window in every block) and `learned` (blocks of FX gains learned), since the step 9b acceptance `resets` (tracks whose blocks were dropped since the start: items changed, or a track replaced) and `reset_last` (the last one's name), ms and windows of the last cycle, windows a second) The raw peaks `m` and `mm` of step 3 were dropped: X and Z say more, and formatting 448 numbers cost a third of a frame at 224 tracks |
| `graph` | when it changes, at most twice a second | JSON: `gseq`, `version`, `tab`, `project`, `name`, `tracks` (`i`, `guid`, `name`, `color`, `parent`, `depth`, `folder`, and the role fields listed under "Step 4 design, as built"), `master`, `view` (from `.rfv.json`: `mode`, `tracks`, `groups`, the user's `roles` and `paths`, and since step 9b `sections`), `stage` (`mode`, `objects`: what is drawn, from engine/rfv_view.lua: `kind` track/return/bus/group, `track`, `parent`, `open`, a group's `name`, `group` and `members`, and `sum`: the tracks whose heard powers make the object's X and Z when it is not its own track's), `history` (`undo`, `redo`: steps the page's Undo and Redo can take, since the step-6 review), `store` (error, `kept_as`, `recovered_from`, `missing` tracks the choices name, `candidates`: other choices files in the folder that fit the project), `roles`; per track since step 6 also `sends` (audio send destinations), `via` and `was` (the routing's own role under a role the user set). `name` is the name the user gave (`P_NAME`), empty for an unnamed track; the page labels it "Track N" by its current position |
| `owner` | at start | the running instance's token. A newer instance writes its own, and the older one stops on its next tick |
| `command` | by the page | `stop` asks the engine to stop |
| `cmd` | by the page | a change to the choices: `<seq>\|<bytes>\|<json>` with `op` show, add, remove (tracks by graph index `k` plus `gseq`, or by GUID `g`), take (REAPER's selection: `how` show/add/group), group, ungroup, rename, mode, role, path, forget, adopt, undo, redo, sections (`source`: regions, markers#, markers, off; since step 9b), and `tab`. The engine checks the length (the web interface cuts long requests silently), the tab and the graph version, applies it through the store, clears the key (a command is never applied twice; one waiting at start is dropped) and answers in the frame |
| `ping` | by the actions | `<n>\|<what happened>`: the choices changed; the engine reads them at once and shows the line on the page |
| `all_cmd` | by the "Show all or chosen tracks" action | its command number, so an engine started before the action was registered can keep its light |
| `sections` | once a second, since step 9b | JSON: `gseq` (the graph version its objects follow), `tab`, `source` (the project's choice), `used` (where they came from: regions, markers#, markers, off), `list` of `{ name, a, b }` (seconds) with, once worked out while a page is open, `played` (the share of its stage, by power, that the meters measured while it played; a part with no FX, known exactly from its files, is not counted as measured), `read` (since the step 9b review: the share of the files its stage rests on with a window read in every block, each track as one: every track its Y and width need, and every other track whose level needs its files), `ma`, `o`, `oy`, `ob`, `nl` (as in the frame, for the section's average stage; the fifth number of an `oy` tuple is the windows read against a 2 s readout's, at most 1) |
| `page_seen` | by the page, every 2 s | the browser's time in ms. A value under 10 s old means a page is open, so starting the engine does not open another browser tab |
| `page_sect` | by the stage page, every 2 s and when the choice changes (since the step 9b review) | `<ms>\|<start>\|<end>` of the section shown, `<ms>\|` for the stage at the cursor. Under 10 s old, the engine works that section out first, whenever its stage is a second old, and publishes `sections` at once |
| `gseq_last` | with each graph | the last graph version, so a restarted engine keeps counting up |
| `error` | on an error | the last error with its traceback |
| `debug_fault` | by tests | `1` makes the next tick raise an error once |

Two pages (since step 8): the stage, `index.html` (with `stage.js`, `stage_map.js` and three.js in `vendor/three/`), and the debug page with every track, `debug.html`. Each page reads `/_/GET/EXTSTATE/<section>/frame` (section from `?section=`, default `ReaperForVisual`) every 100 ms, timed from the start of each request, and `graph` only when `gseq` changes. It polls once a second while the engine is stopped or not started, and not at all while its tab is hidden. Each request is abandoned after 2 s. It undoes the web interface's escaping of `\\`, `\n` and `\t` before parsing JSON. It shows "paused" when no new frame has come for 1.5 s and "stopped" when the last frame says so. Measured with a modal dialog open in REAPER: the web interface still answered in 5–38 ms while frames stopped (defer pauses), so "paused" is shown correctly, and the engine resumed by itself when the dialog closed. REAPER's web server does not map a folder to its `index.html`, so the URL is `/rfv/index.html`.

## Reading any project: roles from routing, never from names

Engineers name tracks every which way, so the engine reads the routing graph: folder parents, master/parent send, sends (mode, channels, mute), channel counts, items, and instrument FX. Track names are labels only; track colours are used for drawing.

Built in step 4 (`engine/rfv_snapshot.lua`, `engine/rfv_roles.lua`). Every decision carries a one-line reason, and every case the routing cannot settle carries a flag.

| Role | Recognised by |
|---|---|
| Source | audio items; MIDI items plus an online instrument; an instrument playing MIDI from another track (through a send or a folder link); a live input (armed and monitoring); the extra outputs (channels 3 and up) of a sounding instrument; a track the meter hears although its routing shows no source ("unexplained") |
| Bus (group) | receives tracks on their main path: folder children with their master/parent send on, or tracks whose send is their main path |
| Pass-through | a bus whose only input is another bus (chains such as [TYPE] → [BUS] → [GROUP]); counted as one level |
| Return (drawn as a cloud) | receives only sends that are not anybody's main path (reverb, delay, parallel processing), or only sends at the same level as a main path (parallel buses) |
| Mix bus | a bus on the main path of 80% or more of the sources, when there are at least 3 (otherwise, in a template, of the feeding tracks); there can be several (a chain, or MIX A and MIX B in parallel) |
| Ignored | empty; MIDI without an online instrument; MIDI that only feeds an instrument; sidechain input only; a folder whose tracks all send elsewhere ("organizing"); anything that never reaches the master (hardware output only, parent send on channels 3 and up) |
| Layer | only when the user says so (`roles`: `layer:<GUID>`) |

**Main path.** With the master/parent send on, it is the parent, unless that folder never reaches the master and a send does (an organizing folder with its own send off, its children left at REAPER's default): then the send is the main path. With the parent send off, the loudest audio send, preferring destinations that reach the master; sends within 0.005 dB tie, and the tie goes to the destination first in track order (flag `tie`; `.rfv.json` `paths` can choose another). The other tied destinations are "same-level" paths: they count for mix-bus membership, and a bus fed only that way is a parallel return.

**Group** = the object just under the nearest mix bus on the main path (or just under the master), possibly the track itself. **Level** = buses between a track and its group, pass-throughs not counted. **Mix-bus share** is counted on the sources, so spare empty tracks outside the mix bus do not dilute it (OurGoodWolf with ten spare tracks added kept PreMaster; counted on all tracks it fell to 71% and every group merged into one). A template with fewer than 3 sources counts the **feeding tracks** instead: tracks that could become a source (empty tracks, MIDI tracks whose synth cannot be seen), so templates without items still get their structure.

Flags: `tie`, `parallel`, `unexplained`, `midi_no_instr`, `side_parent`, `feedback` (cases to check), `hw_only`, `own_sound`, `receives_sends`, `live`, `muted`, `user`.

### Principle (owner, 2026-10-11)

The user decides which tracks to observe; ReaperForVisual's job is only to display that observation well. Roles decide **how** a chosen track is drawn and where it is heard, never **whether** it is shown.

### Decisions for step 4 (owner, 2026-10-11)

1. **Default group level: the level just under the mix bus**, for example Drums, Vocals, Bass, Guitars, Keys, Percussion and FX in OurGoodWolf. The full hierarchy is kept; the page has a switch for deeper levels and can expand a group or collapse it into one object measured at its bus output.
2. **Dry path when sends tie.** A track with its master/parent send off follows its loudest audio send. On an exact tie it takes the destination earliest in track order, which is deterministic because a sender sees its sends in destination-track order. The track is flagged "main path guessed by track order", and the user can override it.
3. **Parallel buses by routing only (version 1).** Every bus fed only by parallel sends is drawn as a cloud and flagged "reverb/delay or parallel processing". The user can mark it a layer of a group (`roles`: `layer:<GUID>`). Hints from plugin names may come later, once there is evidence for them.
4. **Live inputs are sources.** A track that is armed with monitoring that sounds now has its X and Z from meters; Y is "?" (no items for the accessor). *Found in the step-4 review:* the meter of an armed track shows its **input** (fader at −inf and pan hard left still read L = R = −76 dB), so X and Z cannot come from that track's own meter. To decide at step 5: estimate from the input meter and the track's pan and fader (marked estimated), read the destination bus when the input is its only member, or show "?".

### Step 4 design, as built

- **Routing snapshot.** Plain data per track: GUID, name, folder depth and parent, master/parent send with its channel offset and count, channel count, mute, polarity, FX chain on and FX count, an online enabled instrument, whether it has an unmuted audio item (read up to the first one) or else a MIDI item (by active take), hardware outputs, arm, input and monitoring; and every send (source, destination, mode, volume, pan, mute, mono, polarity, channels, MIDI flags). Pan, width and volume of tracks are left out: they move with automation, so step 5 reads them live. Two producers: the API (`SN.from_api`, 1.4 ms at 224 tracks; counting every item cost 17.8 ms at 5,024 items, so the snapshot stops at the first audio item) and the `.rpp` text (`tools/rfv_rpp.lua`, for tests and for reading the owner's projects without opening them). They agree field by field on four fixtures.
- **Classifier** `RO.classify(snapshot, opts)`: a pure function, 0.9–1.5 ms at 224 tracks. `opts` holds the user's `roles` and `paths` from `.rfv.json` and the tracks the meter safety net heard.
- **In the engine.** The routing is read when the state counter moves (at most twice a second) and at least every 2 s, because arm, monitoring and other changes without an undo point do not move the counter. The classifier runs again only when the snapshot, the overrides or the safety net changed; the graph is rebuilt only when roles, names, colours, the store or the tab changed (building and encoding it costs ~20 ms at 224 tracks, 70 KB, so a knob turn must not trigger it).
- **Meter safety net.** Each frame, tracks that are ignored by routing yet reach the master are listened to; one above −60 dBFS in 5 frames (0.5 s) is classified again as a source of kind `unexplained` until the engine stops. The JS Tone Generator was caught within 0.5 s while the transport was stopped.
- **Graph fields per track:** `role`, `kind`, `reason`, `flags`, `group` (track index or null), `level`, `members`, `dry` (index, −1 for the master, null for nowhere), `path` (indexes of the buses above), `layer_of`. Top level `roles`: `mixbuses`, `feeders`, `classified` (count), `classify_ms`, `snapshot_ms`, `heard`.

### Facts behind it (2026-10-11)

- **Survey of the owner's 16 projects** (`tools/rpp_survey.py`, text only):
  - OurGoodWolf: folders as real buses (18 folders, 14 sends, 5 sidechains).
  - SessionHoangDa: folders only organize; 45 of 57 tracks have the master send off and audio travels by sends, for example source → [TYPE] → [BUS] → [GROUP] → PreMaster, with pass-through chains.
  - Tiki Horea mix template (135 tracks): two parallel mix buses (MIX A and MIX B), drum parallel buses fed at the same level as DRUMS, more than 10 vocal returns including a parallel compressor.
  - Templates and recording sessions have no items (ForRecord: 12 armed tracks).
- **`.rpp` encodings, verified against the API.**
  - `AUXRECV src mode vol pan mute mono phase srcchan dstchan …`, where channel pair 3/4 = 2, mono channel 3 = 1026, MIDI only = −1.
  - `MAINSEND on offset`.
  - `REC armed input monitor …`.
  - `BYPASS bypass offline …` before an FX.
- **Instruments.** An instrument set offline returns −1 from `TrackFX_GetInstrument`, which is right because it is silent. A JS synth is not detected at all, and the stock JS Tone Generator sounds (−12 dB) even while the transport is stopped.
- **MIDI** travels through the master/parent send: a ReaSynth on a folder parent played its child's MIDI items. `I_MIDIFLAGS` with low 5 bits 31 turns a send's MIDI off.
- **Automation is not in the API's values.** During 18.8 s of playback with mute and volume envelopes, `B_MUTE` and `D_VOL` kept their base values (so roles never churn with automation). Step 5 must not take pan or volume from the API where envelopes exist: evaluate the envelope or use the meters. Send automation was not measured directly.
- **MIDI "None"** chosen in the routing window is stored as 31 (21 sends in the owner's projects).
- **Names** holding all three quote marks lose the backtick in the `.rpp` (REAPER writes it as an apostrophe); the API keeps it.
- **More encodings:** `MAINSEND_NCH n` is a separate line; takes are separated by `TAKE` lines with `SEL` on the active one; files saved by REAPER 6.33 have no `MASTER_TRACKID`.
- **The state counter** does not move inside one script run; it moves when an undo point is made. So the engine also looks every 2 s.
- **Read-only, after step 4:** of three 600 s gates on the step-4 engine, one saw the state counter move once while playing (undo, redo and dirty unchanged); the others, one of them watching every tick, saw nothing. The engine and store make only reading calls (listed). The read-only test now logs each move with its time and phase.
- **Real projects, as classified** (expected tables in `tests/roles_expected.lua`, written from the routing before the classifier ran): OurGoodWolf has PreMaster as its mix bus and the groups Drums, Percussion, Bass, Guitars, Keys, Vocals and FX; SessionHoangDa has PreMaster with Vocals, Instruments and Drums under it, reached through send chains; the Tiki Horea template has two mix buses (MIX A, and MIX B as a parallel one) with ALL DRUM, ALL MUSIC and ALL VOCALS under them; ForRecord has 9 live inputs including a VST3 piano played from a MIDI input. The Brauerize template has no mix bus at all: its four buses A–D go to the master, each holding a part of the mix, so they are its groups.

## Step 5 research (planning, 2026-10-11)

Scripts in the session scratchpad: `step5_research.py`, `step5_windows.py`, `step5_heard.py`; live probes `step5_live_probe.lua`, `step5_hold_probe.lua`.

- **The meter, measured live:** it refreshes about every 46 ms and falls 1.4 dB per refresh (30 dB/s, the `vudecay` setting). Reading every 31 ms repeats one reading in three. `Track_GetPeakHoldDB` read and then cleared gives the raw peak since the last read (or −150 dB when no refresh came).
- **Automation:** `D_VOL`, `D_PAN`, `B_MUTE` and `GetTrackUIVolPan` all return the base values during automated playback; only `Envelope_Evaluate` at the play position gives what plays.
- **X from meters** (emulated as measured, 37-track band, 166 track-sections, tracks and buses): 0.00° median, p90 0.5°, max 2.2° against the rendered truth; worst on wide decorrelated stereo (rooms, reverb). Over 0.5 s windows p90 1.2°.
- **Z from meters**, crest fitted on the meter's jumps, leave-one-track-out, against `level_db`:

  | Readings | Per section | 2 s windows | 0.5 s windows |
  |---|---|---|---|
  | as they are (decayed) | 3.0 dB median, p90 5.4 | | |
  | raw peaks rebuilt from the fixed decay | 1.2–1.3, p90 2.8 | 1.5, p90 3.7 | 2.5, p90 9.3 |
  | raw peaks from a cleared peak hold | 0.9, p90 2.8 | 1.3, p90 3.2 | 1.3, p90 3.3 |

  `level_active_db` and LUFS are followed slightly less well (1.2–1.6 dB). All of this is one song.
- **Heard position**, on nest: REAPER's pan matrix applied bus by bus is exact (0.00°, 0.00 dB) for balance with every law, dual pan and two levels of buses; stereo mode with width needs the child's L/R correlation (0.9°, 2.4 dB off if assumed 1 for an uncorrelated source; exact with it, which step 7 measures); a widener on the bus is invisible to it (−9.3°, −7 dB). Scaling each channel by the bus meter over the sum of its children's meters catches the widener but fails on correlated children (+2.7 dB) and on stereo-mode crossfeed (22°).
- **Material:** the only full multitrack on this computer is OurGoodWolf (25 sources); SessionHoangDa has 3 recorded stems.

### Decisions for step 5 (owner, 2026-10-11)

1. **Z from the ordinary meter**, with the raw peaks rebuilt from its fixed decay: no side effect on REAPER. The gate is Z ≤ 1.5 dB median per section (the research expects about 1.2). Reading and clearing the peak hold (more accurate and quicker, but it resets REAPER's own hold readout on the tracks shown) may come later as a switch, in step 10.
2. **Responsiveness:** X over the last 0.5 s, Z over the last 2 s.
3. **Live inputs** (an armed track meters its input): X and Z estimated from the input meter through the track's own pan and fader (automation included), FX ignored, marked "estimated"; read from the destination bus instead when the input is that bus's only member.
4. **A second song** for the crest model: SessionHoangDa's three recorded stems for now; a full second multitrack before release (step 10). Downloading one needs the owner's word first.
5. **X and Z are computed in the engine** (Lua): they need every meter refresh (~46 ms), while the page sees ten frames a second. The page keeps layout and drawing.

### Step 5 as built (2026-10-11)

Files: `engine/rfv_meter.lua` (meter readings to X and Z), `engine/rfv_heard.lua` (heard X and Z), the engine's frame; `tools/meter_reference.py` (the same pipeline in Python, emulating REAPER's meter on rendered stems, and the crest fit), `tools/truth_share.py` (the share-of-the-mix truth); tests `meter_logic`, `meter_live`, `axes_live`, `axes_second`, `heard_logic`, `heard_automation`, `live_input`.

**What the meter is**, measured: it refreshes about every 47 ms (it wobbles between ~46 and ~47 ms), and at each refresh shows max(peak since the last refresh, its previous value fallen one step). The step was 1.4148 dB, 30 dB/s, REAPER's `vudecay` setting. Three things the emulation did not have showed up live and shaped the rules:
- the step varies a little with the refresh (1.38 dB now and then), so "on the decay line" means a fall of at least 0.95 of a step, not an exact multiple;
- REAPER stalls now and then, and one reading then falls several steps;
- REAPER renders audio in bursts, so a refresh can see no audio: a steady tone's meter dips one step and comes straight back. Such a lone dip between two exact readings is dropped (without this a steady sine read 1.5 dB low).

**Pipeline** (`rfv_meter.lua`, compared reading by reading with the Python reference: equal to 1e-14): every tick (~31 ms) each meter is read; a new refresh is a changed reading, or the same reading standing longer than 55 ms (a repeated peak, with the previous reading's status); a reading on the decay line counts as 0.4 of itself, any other as the exact peak; under −100 dBFS is silence. X = tangent law on the summed squares of the last 0.5 s; Z = 10·log10(mean S) − (4.546 + 0.502 · 10·log10(max S / mean S)) over the last 2 s, S = L² + R². No exact reading in the 2 s means silence. Running sums and a max deque keep an estimate at a fixed cost (0.06 ms for 84 sounding tracks, from 0.62 ms). The decay step is measured live as the commonest fall (0.01 dB bins), the refresh as whole decays' time over their steps.

**Crest model**: of the cheap features tried on 2 s windows (mean or median jump, the share of readings on the line, mean/median, max/mean, and pairs), max/mean alone did best: 1.46 dB median (p90 3.17) leave-one-track-out on the band fixture; mean jump 1.63 (4.20). Coefficients fitted on the band fixture.

**Heard** (`rfv_heard.lua`): a track's own powers (from X and Z) go up its main path: through the way in (a folder as it is; a send by its volume, pan and mono switch), then the bus's FX gain where its chain has active FX (its measured output over what its inputs predict, so a compressor's work on the whole group is shared out in proportion), then the bus's fader and pan as REAPER's measured pan matrix, and finally the master's. Correlation is taken as none until step 7 (it matters only for stereo pan mode). Fader, pan and width are read every frame and active Volume, Pan and Width envelopes are evaluated at the play position (the API's values ignore automation; trim/read mode combines both), with modes, laws and which envelopes exist cached per routing snapshot. Pan mode and law −1 take the project's defaults from the config variables `panmode` and `panlaw`, which follow the active project (measured; `GetSetProjectInfo` knows no such keys).

**Image gap**: a bus with FX whose measured image sits more than 4° from where its inputs put it, smoothed over ~1 s, is flagged. A widener opens one (9.3°, and its inputs' heard X is then off); correlated inputs panned apart (the band's room mics) open one too while each input's heard X stays right. Meters cannot tell the two apart, so the flag says only that the bus's image is not its tracks' sum.

**Live inputs** (decision 3): an armed, monitored track's own X and Z are its input meter carried through its own pan and fader (`ae`); the only input of a bus is heard where the bus is (`hb`); armed and not monitored is unknown. Checked on the interface's input noise: pan hard left read −30.0°, the bus case +30.0°.

**Ground truth for heard**: "heard" is now rendered with every send muted (main path only). A track rendered alone through a bus compressor is louder than its part in the mix (band: Room 3 alone −25.5 dB, its share −32.2 dB), so heard Z is judged against `share` (`tools/truth_share.py`: per 50 ms, the track's part of the bus input times the bus output, bus by bus). Share equals the solo render wherever the buses are linear (all of nest, the band's vocal buses). Heard X is judged against the solo render (pan and linear FX are exact there).

**Cost at 224 tracks** (84 sounding): ticks 0.3 ms median (reading every meter every tick), frame ticks 1.5 ms p95; frame 3.8 KB.

### Step 5 reviewed and revised (2026-10-12)

Three-lens review; each doubt was checked in a temporary tab (probe scripts in the session scratchpad) and against the owner's 16 projects (as text). The owner chose to fix everything that could be fixed.

**What REAPER does, measured** (the facts behind the fixes):
- **The meter** has two writers: the audio thread raises it at once whenever audio peaks above it, and REAPER's UI lowers it one step per meter tick unless a peak since the last tick holds it up. Inside one script call that held the UI for 0.4 s, noise rose twice and a decaying tone never fell. The ticks follow REAPER's meter update setting (`vuupdfreq`, 30 Hz = 33.3 ms) rounded up by Windows' 15.6 ms timer: 46.9 ms here. The audio buffer (128 samples, 2.7 ms) plays no part. "At each refresh it shows max(peak since the last refresh, previous value fallen one step)", above, is the tick's half of it; on noise nearly every reading differs.
- **Automation:** every envelope combines with its knob the same way in every automation mode (trim/read, read, touch, latch, and write before anything is touched): Volume, Trim Volume and Volume (Pre-FX) multiply the fader; Pan adds to the pan knob; Width multiplies the width knob; Pan (Pre-FX) is a balance stage of its own before the FX. Send envelopes likewise: Send Volume multiplies, Send Pan adds, Send Mute at 0 mutes. Showing a volume envelope moves the fader's value into it (`D_VOL` reads 1.0 afterwards). A VCA lead's fader and volume envelope multiply into its followers, whose own `D_VOL` stays 1.
- **Mute:** a muted track's meter falls silent (the button, or a Mute envelope at 0; the button mutes even with the envelope at 1, and with all automation bypassed). A folder muted while playing leaves its child's meter showing the child; muted before playback starts, the child is not processed at all.
- **Solo:** the meters of tracks a solo silences keep showing their signal, and only the master's sum leaves them out. The exception is a soloed child's sibling, which is cut on its way into the folder, so the folder's meter holds only what passes. What passes: a soloed track; everything feeding a soloed bus, through folders and sends alike; a soloed child, carried by its folder parents; "solo in place" also through the sends on its way, while plain solo stops at a send to a bus that is not soloed; solo defeat always. This was decoded from the muted master's meter, with each track playing an in-phase sine at a binary weight.
- **The master's meter** shows the sum before the master's mute.
- **The owner's projects:** 15 tracks saved soloed (4 of 16 projects); Trim Volume automation on two buses of the current mix ([GROUP] Vocals 0 to +1 dB, [SUB] Lead Vox 0 to +3 dB; both have FX, so the measured FX gain already held it); every send post-fader; no send automation, no read/touch/latch saved, no track groups; two buses that receive side sends (MIX B and ALL DRUM in the Tiki Horea template).
- Reading a send's envelopes changes nothing: they are found by listing the track's envelopes ("Send Volume", "Send Pan", "Send Mute" with `I_SEND_IDX` = the send's index + 1). `P_ENV:<VOLENV` on a send without one returns an empty, inactive envelope and leaves the chunk, the state counter and the dirty flag unchanged; the engine does not use it.

**Fixed:**
- **G1, G2. Solo and mute** (`HD.audible`). Mute buttons, Mute envelopes, solo and solo defeat are read every frame. Heard is null for what cannot reach the master; `hm` lists the tracks that sound but are silenced on their way, and `solo` flags the frame. Own is null for a muted track (its meter would take up to 2 s to fall). A bus that carries a soloed track passes it.
- **G3. Automation modes:** the build replaced the fader and the pan knob by their envelopes outside trim/read; they now combine in every mode.
- **G4. Every stage on the way:** Trim Volume, Volume (Pre-FX), Pan (Pre-FX), Width, VCA leads, and the main-path send's own envelopes (volume, pan, mute) are evaluated. A send taken after the FX but before the fader starts from the track's output with its fader and pan undone (`HD.untap`, uncorrelated channels). A send taken before the FX does the same and ignores the FX; such tracks are listed in `ha`.
- **G5. FX gain:**
  - Every audio send into a bus counts in the bus's prediction, not only the main paths.
  - A bus with FX that sounds nothing while its inputs play gets gain 0.
  - There is no FX gain on a bus with a sound of its own or on an armed bus: neither can be measured.
- **G6. Decay readout:**
  - The rate is the median of the last 32 whole decays' dB per second, taken while playing; the refresh is the step over that rate.
  - The step histogram halves every 400 falls, so a changed setting is followed.
  - Before the fix, while stopped, a meter left without audio dropped at once and pulled the reported refresh from 47 to 42 ms; the card read 34 dB/s.
- **G7. Crest model:**
  - Coefficients are fitted on REAPER's own readings, recorded while the band fixture played (`tests/meter_record_test.lua`, `tools/meter_reference.py --live-reads`): 4.480 + 0.467 × feature, against the emulation's 4.546 and 0.502.
  - An emulation of the new meter model ("live": rises between ticks) gave 5.02 and 0.56 and judged the unseen recordings at 1.39 dB, so the old "held" emulation stays the default for fits.
  - The coefficients follow the measured step and refresh (`MT.crest`, a grid fitted on the emulation of 4 refreshes × 6 decay rates). On held-out settings the fixed coefficients gave 1.07–1.73 dB and the grid 0.95–1.19 dB (their own fits: 0.95–1.20).
  - The exception is a meter faster than the reads (16.7 ms): median 1.11 → 1.07 dB, but p90 2.2 → 3.0.

**After the revision, live:**
- Band: own Z 0.93 dB (p90 2.3), heard Z 0.92 dB (p90 2.7), X 0.00° (p90 0.7 own, 0.4 heard).
- SessionHoangDa, never fitted: 0.83 dB per 2 s window (p90 2.1), 0.80 per 20 s (p90 1.9).
- nest: heard X 0.04°, heard Z change 0.02 dB.
- `heard_stages` (new): a bus's only input is heard exactly as the bus's own meter (0.00 dB, 0.00°) through trim, pre-FX volume, pre-FX pan, width, VCA, read mode and a pre-fader send. A side send is counted (+7.2 dB against the meters' +7.0; uncounted it would be +14.5). Silenced buses and the solo phase are right in every frame.
- Cost at 224 tracks: tick 0.26 ms median, 1.7 ms p95 (the frame ticks), 3.6 ms max. Each track's envelopes, sends and VCA groups are read again only when the state counter moves, or every 10 s.

**Left as they are (decided):**
- U1: while stopped, FX that run when stopped (the owner's REAPER is set so) make dither or noise that the meters show (master −86 dB). The page's relative threshold (step 8) and stopped mode (step 9) are where this belongs.
- U2: the master's mute is not applied. It acts like a monitor mute and the stage stays; the tests rely on it.

## Step 6 research (planning, 2026-10-12)

- **The page's write channel**, measured with requests to `/_/SET/EXTSTATE/ReaperForVisual_test/probe/<value>` read back through the bridge:
  - Percent-encoded values arrive intact: GUID lists, JSON, `|`, `+`, spaces and Vietnamese. Each request took 13–68 ms.
  - A request whose whole line passes about 1 KB is **cut silently**: HTTP 200, and the stored value just ends. Index lists stopped at 657 bytes and GUID lists at 855 bytes (about 22 GUIDs). So every command from the page needs a length or checksum the engine checks, and the page must hear back that it was applied.
- **What the build stands on:**
  - The store (`S.edit` reads, changes and writes at once; `S.follow` picks up another script's change within a second; `S.missing`, `S.adoption_candidates` and `st.error` for the page) and the spec's `view`, `groups`, `roles` and `paths` exist since step 1.
  - The classifier already applies `roles` and `paths` (step 4).
  - A script run as an action makes no undo point and leaves dirty unchanged if it ends with `reaper.defer(function() end)` (step 3). Selecting tracks changes neither (step 1).

### Decisions for step 6 (owner, 2026-10-13)

1. **Five actions in REAPER:** Show selected tracks (replaces the chosen tracks), Add selected tracks, Remove selected tracks, Group selected tracks, Show all / chosen (toggle). The page offers the same and more (role and main-path corrections, renaming groups, forgetting deleted tracks).
2. **Loading them:** the five scripts are registered in the owner's Action list (`AddRemoveReaScript`, written to `reaper-kb.ini`; reversible).
3. **A display-only group is one object on the stage:** its X and Z come from its members' heard powers added up, and it opens to show the members, as a bus does but without one existing.
4. **Show selected replaces the chosen tracks only.** Groups stay in the file and show again when their members are chosen.

Also settled without a question:
- Frames keep every track, because the checklist and "all" need them.
- A selected master track is ignored.
- A new group is named from its members' common name, and is renamed on the page.
- A deleted track stays in the file (it may come back with undo) and is listed as missing, with a way to forget it.

### Step 6 as built (2026-10-13)

Files:
- `engine/rfv_view.lua`: the changes to the choices, and the stage they resolve to.
- `engine/rfv_actions.lua` and the five `ReaperForVisual - ....lua` actions.
- The engine's command channel, ping and stage.
- The debug page's view section, Stage table and per-track Show, Role and Main path.
- Tests: `view_logic`, `view_actions`, `view_commands`, and the hand session `view_page_session.lua`.

How it works:
- **The stage** is a flat list with parent links, so nested buses nest: every chosen track is an object. One in a display group hangs under the group; otherwise it hangs under the nearest chosen bus above it on its main path. A chosen bus with nothing under it is closed and measured at its output. "All" gives one closed object per group under the mix bus (decision 1-A of step 4), and since the review every return on its own (U2 below).
- **Heard X and Z of an object** come in the frame's `o`: a track, return or bus has its own heard values; a group adds its members' heard powers (checked live against its members: −10.7 dB both).
- **The actions** read REAPER's selection (the master excluded), write through the store and ping the engine. With nothing selected, Show, Add, Remove and Group change nothing and say so.
- **Page commands** name tracks by graph index, so 150 fit in a request; GUIDs are used only for tracks the project no longer has. They are checked for length, tab and graph version; a command refused because the tracks changed is sent again once by the page.

Measured:
- Each action left undo, redo, the dirty flag and the state counter as they were, with a change of the user's kind pending, and the change stayed pending.
- The engine's graph showed an action's change 31–34 ms after it ran (ping), against up to 1 s by polling the file.
- A view survived reordering, renaming, saving and reopening.
- All 23 command cases behaved as specified: a command cut short (20 of 64 bytes) was refused, a resend ignored, another tab and a changed graph refused, role and main path set and undone (the routing's own answer stays in the reason), Vietnamese group names, taking REAPER's selection, forgetting a deleted track, adopting choices found beside the project.
- On the real page, through REAPER's web interface, ticking, role and path choices, all/chosen and Clear did what they say, and the file afterwards held exactly them.
- Cost at 224 tracks: tick 0.28 ms median, 1.76 ms p95, 4.7 ms max (unchanged); the graph grew from 70 to 79 KB and is sent only when it changes.

Found and fixed on the way:
- Every module loads its own copy of `rfv_json.lua`, which recognised arrays by identity, so an empty list made by one copy was written as `{}` by another. The graph's empty view was affected since step 3. Markers are now recognised by their tag.
- The command key outlived the engine: a new instance applied the last command again. Commands are now consumed, and one waiting at start is dropped.
- Deferred test code runs inside the bridge's own script. An error there raised a modal dialog and ended the bridge, which had to be started again by hand. The harness now wraps deferred code (the error is reported, with no dialog) and runs each test's cleanup even when the test fails.
- A test engine left running by a failed test was toggled off, not restarted, by the next test's launcher (set_action_options 1). The launcher now waits for it to stop.
- On the page, "auto" now names the routing's own answer while the user's choice is in force.

### Step 6 reviewed and revised (2026-10-13)

The review (three lenses) found five gaps and four things to improve for the user. The owner chose all the recommendations, with U2 = a (returns as their own clouds) and U4 only in a form every user can install without help.

| | Found | Done |
|---|---|---|
| G1 | A display group holding a bus and a track inside it counted the track twice (+1.76 dB in the example). | A group adds up only the members no other member carries on its main path (`sum`). Checked: {Drums, Kick in} = Drums alone; live, a group of siblings still equals its members added up (−10.5 dB both). |
| G2 | An action run twice within one defer tick (a held shortcut repeats every ~33 ms) found its first run still waiting for its closing defer, and REAPER raised the modal "ReaScript task control" dialog (measured in the review). | Each action starts with `set_action_options(1 \| 2)`: the waiting run is ended and the new one runs, without asking. Measured: run twice in one tick, both runs done, no dialog. |
| G3 | In "all" the page's Show boxes showed the chosen tracks, and ticking one switched back to "chosen" (the stage jumped). | In "all" the boxes are disabled, with a line saying the chosen tracks are kept and how to go back to them. |
| G4 | With every chosen track deleted, the empty stage said "Nothing is chosen yet". | It says that the chosen tracks are no longer in the project, that an undo in REAPER brings them back, and points to Forget. |
| G5 | The spec said "all" shows "every track that is heard"; it shows the default level. | Spec, page and action texts say "the whole mix: one object per group under the mix bus, every return on its own". |
| U1 | No way back from a slip (Clear, Show selected with a wrong selection, Forget). | The engine keeps every version of a tab's choices it sees (made by the page, an action or another program), 20 per tab, in memory while it runs; the page has Undo and Redo, and a new change clears what could be redone. Checked: an action's change undone and redone from the page; the project untouched. |
| U2 | "All" on the owner's mix drew the five returns as one "[FX] Effects" object, because they sit in that folder. | In "all" every return is its own object wherever it sits; a group that holds returns is the rest of it (its other tracks added up), and a group left with nothing is not drawn. The owner's mix: 6 groups and 5 returns (was 7 objects). That sum leaves out sends into the group's buses from outside it and a folder's own items, which only its meter holds. |
| U3 | The "Show all or chosen tracks" button had no light. | The action lights its own button, and the engine keeps the light in step with the active tab (also when another program changes the mode), comparing it with REAPER's every frame. Measured: one script can set another script's light (`SetToggleCommandState`), not a built-in action's; neither touches the project. A test engine drives only the light of its own launcher. |
| U4 | The actions are only in the Action list. | The owner chose (b) + (c), in a form every user can install without help. (b) A sixth action, "ReaperForVisual - View menu" (`engine/rfv_menu.lua`): every view action in one popup at the mouse, the selection actions greyed with a reason while nothing is selected, "Show the whole mix" ticked while shown, Undo and Redo sent to the running engine as page commands (greyed with a reason while it is not running or has nothing to take back). One key or one menu item holds everything, and nothing of the user's menus is replaced. (c) The README says how to load the actions and put them on a key, in the track's right-click menu or on a toolbar, with REAPER 7.82's own labels (read from `reaper.exe`). Nothing was changed in the owner's menus. `view_menu` checks what the menu shows and what each item does, live; the popup itself is modal and is tried by hand. It is tried without a window first and, if REAPER shows nothing that way (it returns at once), in a window of no size at the mouse; ExtState `menu_path` records which. **Tried by the owner by the README alone:** loaded the script (the Load ReaScript dialog takes several files at once), put it on a floating toolbar, chose tracks and undid it from the menu; the menu showed at the mouse without a window (`menu_path`: "without a window"). The action REAPER named for it, `_RSb8bbcb9f…`, is the SHA-1 of its path computed beforehand. |

Found on the way (the suite after these fixes, 21/23): the two long playback tests failed one after the other. `axes_live` missed its end (playback stopped at the project's end between two reads 0.12 s apart, so no frame fell in the last 0.2 s), and its sampling loop, deferred inside the bridge's script, kept running. In the next test it read that test's frames, saw the position pass 95.8 s and called `OnStopButtonEx` with the closed tab's pointer: the new test's playback stopped at ~96 s (788 frames, the band test's count), and a lone rerun of it collected 1,966 frames, twice the normal, because the left-over loop was still feeding it. Most likely the stale pointer stopped the active project; it was not tried again on purpose, with the owner's unsaved project open. Fixed in the harness: every test begins and ends a new generation of deferred callbacks, and callbacks of an older one are dropped (the bridge's own listener, defined in `claude_bridge.lua`, is never dropped: checked on its call stack before the change). Both tests also take "stopped within 1 s of the end" as the end, and say how far playback got when it did not.

Measured on the way: every bridge command moves the active project's state counter by one, read-only ones too, with no undo point and dirty unchanged (three empty commands read 280, 281, 282). So a test may compare the counter only within one command or from deferred code; `view_menu` first compared it across steps and saw +4 for its 4 steps. This is a likely cause of the single +1 one of the step-4 read-only gates saw (open since then): any bridge command sent while it ran.

Measured on the way: REAPER names a script's action `_RS` followed by the SHA-1 of its path under `Scripts`, upper-case, with forward slashes (both checked: `REAPERFORVISUAL/REAPERFORVISUAL.LUA`). So the five actions have the same names on every computer that installs them in `Scripts/ReaperForVisual/`.

## Step 7 research (planning, 2026-10-13)

Measured on the band fixture against its ground truth (own: each track's output after its FX, fader and pan), in a temporary tab (probe `y_research_test.lua`, study `y_density_study.py`, both in the session scratchpad):

- **Y from track accessors** (before track FX), 2,048-point windows every 0.2 s, per section: median **0.056 octave** off the truth, p90 0.40, max 2.5. Tracks without track FX: median 0.021, p90 0.21. Tracks with track FX: median 0.16, p90 1.7; the hi-hat and ride, with an 8–9 dB high shelf, read 1.2–2.5 octaves low, because the accessor hears them before their EQ. A shaker read +0.92 octave in a section where it is all but silent (its truth there is leakage).
- **No accessor data** for folders, returns and the MIDI track with ReaSynth (it has items, but `GetAudioAccessorSamples` returns no audio): Y must come from elsewhere or be "?".
- **Width** (L/R correlation) from the same windows: exact (median 0.000) except where something after the items changes it: Gtr 1, through the stereo pan mode with width 0.3 (0.77 before, 0.99 after; the pan matrix is known, so this is computable), and the piano's widener FX (0.32 against 0.48; not computable).
- **One complex FFT per window carries both channels**: with z = L + iR, a = Z(k), b = Z(N−k), the left and right powers are (|a|²+|b|²±2Re(ab))/4 and the cross power Im(ab)/2, whatever the FFT's sign convention. Cost per window: read 0.15 ms, window and FFT 0.017 ms (`reaper.array`'s own FFT), the per-bin loop in Lua 0.23 ms; about 0.4 ms in all.
- **Read-only**: creating 37 accessors took 0.23 ms (4.9 ms the first time) and reading 12,000 windows moved neither the dirty flag, nor undo, nor the state counter.
- **Density matters** (study on the stems, after FX, so only sampling is judged): one window a second put a track's section Y 0.18 octave off in median, p90 1.0. A live Y over the last 2 s, read every 0.5 s and taken per section as the median reading, is 0.085 off at 5 windows a second (p90 0.30), 0.060 at 10, 0.14 at 2. Whole sections from windows summed over the section are 0.025 off at 5 a second (p90 0.16) and 0.015 at 10.
- **Bands**: 1/3-octave band powers alone add about 0.05 octave (their centres stand for every bin). Keeping, per band, both the power and the power-weighted log2 frequency gives the exact centroid back, and still adds up across tracks with any gain: group and bus Y can be built from their members' bands.
- **Budget**: at ~0.4 ms a window, 2 ms per defer cycle (~64 ms a second) covers about 160 windows a second: 16 tracks at 10 a second, 32 at 5.
- **An accessor is a snapshot** (probes `acc_move_test.lua`, `acc_state2_test.lua`): after an item moved, one made before kept reading the old layout until `AudioAccessorUpdate`; a new one read the new layout. `AudioAccessorStateChanged` turns true only a few defer cycles after the edit, never inside the call that made it, and only for some edits: a move, an item muted or unmuted, an item added, a take FX added or bypassed (and a track FX added, which changes nothing it reads). It stayed false for item and take volume, take pan, item length, take start offset, playrate, fades and a take FX parameter. It costs nothing measurable. So the map also keeps its own fingerprint of each track's items, read when the project's state counter moves.
- **Reading the FFT**: `.table()` of 4,096 values takes 0.13 ms, indexing `buf[i]` 0.31 ms; two partial tables, the bins up to 20 kHz and their mirrors, 0.115 ms.

### Decisions for step 7 (owner, 2026-10-13: every recommendation)

1. **Y comes from a map of the files**, not from the live sound: per track, blocks of 0.5 s analysed with 10 windows a second, filled ahead of the play position first (the chosen tracks first), then the rest of the song in the background, and redone when the track's items change. Step 9's stopped mode and sections reuse it.
2. **A track with active FX keeps the Y read before them**, marked "before FX" (an EQ can move it by octaves). A calibration render may come in step 9 or 10.
3. **Where the files say nothing:** a virtual instrument or a live input has Y "?"; a return is estimated from what its sends bring it, marked "≈"; a bus or group adds up its members, weighted by the power each brings, and says what share of that power has no Y.
4. **Budget: 2 ms per defer cycle**, the chosen tracks first.

Settled while building (owner, 2026-10-14, every recommendation):
- The gate's "~2 ms per cycle" is Y's own budget (kept: at most 1.5 ms); a lighter whole cycle at 224 tracks is step 10's.
- Where the budget and the 10 windows a second disagree, the budget wins (26 tracks: 5–6 a second each).
- A take FX parameter change is not seen by the map; accepted, as take FX are rare in mixing.

### Step 7 as built (2026-10-14)

Files:
- `engine/rfv_spectrum.lua`: one window's analysis, the stats that add up, pan matrices, and what every track sounds like at its output (`SP.compose`) and a display group (`SP.combine`).
- `engine/rfv_ymap.lua`: the map of the files, its schedule and budget, and the fingerprints.
- The engine: the tracks the stage needs (`y_need`), the map's work, `spectra_gather` and `spectra_finish`, frame fields `y`, `oy` and `ym`, and the correlations carried through `HD.propagate` (`HD.cov`).
- The debug page: columns Y and Width for tracks and stage objects, with the tags "?", "before FX", "≈ from sends", "anti-phase" and "reading", and a card for the map.
- Tests: `spectrum_logic`, `y_calib`; `axes_live` also judges Y and width (it shows the whole mix through a `.rfv.json` beside the fixture, removed after); `engine_load --set view=all`.

How it works:
- **No 1/3-octave bands after all.** The centroid is a power-weighted mean of log2 f, so each channel's power and its log-frequency moment are enough. They are exact, they add up across windows, blocks and tracks with any gain, and they pass a pan matrix as covariances. A stats vector is `{ PL, PR, C, ML, MR, MC, n }`. If an EQ model (owner's option Q2-b) or a drawn spectrum is wanted later, bands come back.
- **Accessors live within one cycle.** One is made for a track just checked to be valid and destroyed before the cycle ends (~4 µs). One kept longer is a snapshot that goes stale, and could outlive a track the user deletes or a tab the user closes; what REAPER does with such an accessor was not tried, because it could take REAPER down with the owner's project open.
- **Files are read at their own sample rate** (the track's first audio file), which spares REAPER resampling: 0.29 ms a window instead of 0.43 on the band fixture's 44.1 kHz files. Up to four windows go to one track before the next, because the first read on a fresh accessor costs more (0.65 ms alone, 0.45 each in fives).
- **The schedule**: each needed track's readout window first (the last 2 s while playing, the next 2 s while stopped), one window per block at a time; then the rest of the range around the position; then the whole song in the background. A window is not started when its expected cost would pass the budget, but one is always read.
- **What is needed**: each stage object's own track, then everything that reaches one of them on a main path or by a send. With chosen tracks, only those and what feeds them are read (checked: one chosen track out of nine, one read).
- **Edits**: a track's items are fingerprinted (position, length, mute, volume, fades, take offset, playrate, pitch, take volume and pan, channel mode, source, take FX on or off) whenever the project's state counter moves; a change drops the track's blocks. **Not seen: a take FX parameter** (owner, 2026-10-14: accepted, take FX are rare in mixing).
- **Silent or unknown**: a track whose files say nothing in the window is silent when its meter is silent too, and unknown ("?") when its meter sounds (a virtual instrument, a live input, an FX tail). Stopped, a track playing MIDI is unknown.
- **Buses, returns and groups**: a track's input is its own files plus what its inputs bring, each scaled to the power its meter measures (stopped: the files' own powers), through the send's matrix; its output is that through its own pan matrix. The shares with no Y and past unseen FX travel with it. A return's Y is therefore what its sends bring, before its reverb or delay. A display group adds its members by their heard powers.
- **Cycles**: besides reading meters, a cycle publishes a frame, or gathers or finishes Y and width (about five times a second, never with a frame), and the map gets what is left of 2 ms, 1.5 ms at most. At 224 tracks the whole working-out took 1.5–1.8 ms (blocks 0.5–0.6, matrices 0.2, adding up 0.3–0.5, writing 0.3), hence the two cycles.
- **Heard X and Z** now carry each track's left/right correlation through every matrix (`HD.cov`): only paths with crossfeed (a width setting, a mono send) change, and every X and Z test still passes.

Measured:
- Band, playing, the whole mix (`axes_live`): Y off the truth by 0.121 octave in median (gate 0.25), p90 0.64; 0.091 without track FX, 0.219 before their FX (the hi-hat, ride and gated snare top are 2–3 octaves off, marked "before FX"); buses from their tracks 0.180; returns from their sends 0.296; width off by 0.000 in median and p90; the virtual instrument "?" in all its sections and no track with files left without Y. X 0.00° and Z 0.98/0.99 dB, as before. The map read 140 windows a second, 57 % of the readout of 26 tracks with files (5–6 windows a second each instead of the 10 planned: the budget wins, owner 2026-10-14).
- Calib, stopped (`y_calib`): the answers known by arithmetic, the stereo pair panned +0.5 at the truth's 2,096 Hz, anti-phase at −1.000 and tagged on the page, the virtual instrument "?", the project untouched.
- 224 tracks, the whole mix (`engine_load --set view=all`): cycle median 1.85 ms, p95 2.6–2.9 ms (1.76 ms p95 before step 7), the map at 65–68 windows a second (about one a second for each of the 56 tracks with files; the readout fills over time). The roadmap's "~2 ms per cycle" is read as Y's own budget, kept (owner, 2026-10-14); a lighter whole cycle at 224 tracks is step 10's.
- Suite 26/26.

Found and fixed on the way:
- Returns came out "?": the sends the spectra saw were only those into buses (the FX gain's list). The spectra now see every audio send.
- A shaker that plays in one section was "unknown" everywhere else: silent files are now silent when the meter is.
- The map started windows past its budget (1.77 ms in a 1.5 ms budget): it now expects a window's cost.
- The page kept a stale graph when a new engine happened to reach the old graph's version number (a test engine counts afresh): it reads the graph again when frames count from zero.
- A sampling loop of a test that missed its end outlived the test (step 6 review; harness fixed then).

### Step 7 reviewed and revised (2026-10-14)

The review (three lenses) found, and the owner chose every recommendation:

| | Found | Done |
|---|---|---|
| L1 | Stopped, the meters are silent, so a virtual instrument's power is not known and a group holding one shows no unknown share: its Y looks fully known. | Moved to step 9 (stopped mode needs a power for each track without meters). |
| L2 | The item fingerprint leaves out take envelopes (volume, pan) and stretch markers; a send taken before the fader brings its track's shape after its pan; the correlation carried into heard X and Z is the one before the track's FX. | Accepted, as the take FX parameter: rare, and small where they happen. |
| F1 | Is the map safe when the user deletes a track, undoes it, or closes a tab the engine follows? | Checked in temporary tabs while playing with the whole mix read: a track with files deleted, the delete undone (the track came back under its GUID and its Y with it, 1,225 Hz), a new tab followed and closed: the engine ran on, no error. |
| F2 | Y's accuracy is measured on one fixture with REAPER's own FX. On the owner's mix every one of the 25 tracks with files has active FX, so "before FX" applies to all of them. | Noted; a rendered second multitrack is step 10's. |
| F3 | In the 600 s gate the 30 s song was read through in the first seconds: the gate proves reading is read-only, not ten minutes of reading. | Noted. |
| U1 | The Width column showed the correlation, which reads backwards (1.00 is one point). | Width in per cent: (1 − correlation) × 100, so 0 % is one point, 100 % two unrelated channels, above 100 % out of phase (tagged "anti-phase"); the correlation is in the tooltip. Checked on the page: 0 %, 100 %, 200 % anti-phase. |
| U2 | "Before FX" would stand on every track of a real mix (25 of 25 on the owner's). | One note above the tables says Y and width are read from the files before each track's FX; the per-track tag is gone, the share stays in the frame for step 8. |
| U3 | Mapping a whole song takes long: the owner's (260 s, 25 tracks with files) is ~65,000 windows, 8 to 17 minutes. | Moved to step 9: a coarse first pass over the whole song (one window a block), then the dense one; the readout stays dense. |
| U4 | With many tracks "reading" shows almost all the time while playing. | Its tooltip says how much is read and why (a fixed time each cycle, the tracks in turn). |

## Step 8 research (planning, 2026-10-14)

- **The picture the owner liked** (`ReaperMCP/stage-viewer-reference/stage_template.html`, built from renders on 2026-10-10): a floor fan to ±40° with distance rings and 10° rays, the speakers at ±30° and the listener's head with a nose; one sphere per part, at its azimuth (X), at a height from its spectral centroid on a log scale from 40 Hz to 12 kHz (Y), nearer and bigger the louder it is (Z: 2.0 to 5.6 units over 30 dB); widened along the arc by its spread; reverb returns as faint clouds; parts more than 34 dB down hidden; HTML labels kept from overlapping, the louder first; three camera presets with drag, pinch and wheel; hover or tap for details; light and dark themes. It loaded three.js r128 from a CDN.
- **REAPER's web interface as a file server** (measured):
  - `.js` is served as `application/javascript`, so an ES module loads; **`.mjs` is served as `application/octet-stream`, which browsers refuse for modules**. Module files must end in `.js`.
  - About 1 MB a second: a 1,040,012-byte file took 1.02 s, the 32 KB page 0.06 s.
  - **No caching**: `Cache-Control: no-cache, must-revalidate`, an expiry in the past, and a conditional request still gets 200. three.js is fetched in full at each page load (~0.7 s for ~0.7 MB).
  - Serving does not hold REAPER's main thread: defer ticks while 2 × 1 MB were served, p95 35.3 ms and max 48.5 ms, against 33.1 and 46.2 at rest.
- **What the frame already gives the stage** (steps 5 to 7): per stage object heard `[X, Z]` (`o`) and `[Y, correlation, unknown share, unseen-FX share, read share]` (`oy`); per track own and heard values, silenced tracks (`hm`), estimated live inputs (`ae`), heard via their bus (`hb`), approximate (`ha`), buses with an image gap (`hi`); the master's own `[X, Z]` (`ma`). The graph gives the objects, their parent links, names and REAPER colours.

### Decisions for step 8 (owner, 2026-10-14: every recommendation)

1. The stage is `/rfv/index.html`, the page the engine opens; the debug page moves to `/rfv/debug.html`, reached from the stage's Tracks button.
2. three.js 0.170.0 (r170), its `build/three.module.min.js` (691,648 bytes) and licence vendored in `web/vendor/three/`, taken from the npm registry's tarball (7.16 MB) after checking its sha512 against the registry. Every page load fetches it (~0.7 s, no caching); a smaller build may come at the release.
3. Z is the level against the whole mix (the master's own level); without one, against the loudest part.
4. Width on the stage: half the breadth along the arc is 30° × (1 − correlation).
5. A closed bus is a sphere; an open bus or a display group draws its members inside a faint shell with its name; a return is a cloud at its measured place and level.
6. Parts more than 40 dB under the loudest part are not drawn; a slider sets 20 to 60 dB.
7. A part with no Y of its own is drawn at its container's height and marked "?"; a part silenced by mute or solo stays as a hollow sphere; returns are marked "≈"; also "est.", "approx.", "image gap", "anti-phase".
8. Stopped, the stage stays as last heard, dimmed, until step 9 shows the stage at the edit cursor.
9. About: the copyright, the licence, and "the source is the ReaperForVisual folder this page is served from" until the first release links the public repository (no URL guessed now).
10. Colours are the tracks' REAPER colours, a fixed palette where a track has none.

### Step 8 as built (2026-10-14)

Files:
- `web/index.html` (the stage's layout, header, panels, About), `web/stage.js` (scene, parts, frames, labels, camera, commands), `web/stage_map.js` (the axes as numbers only), `web/vendor/three/`; the debug page is now `web/debug.html` with a link back.
- Engine: frame field `mu` (tracks muted themselves).
- Tests: `tests/stage_map_test.mjs` (node, the axes); the page itself was tried live in the in-app browser on the band fixture.

How it works:
- The page polls the frame ten times a second (as the debug page) and reads the graph when it changes or a new engine starts. Each object's target comes from the frame while playing; every screen frame eases each part towards its target (time constant 0.12 s), so the parts glide between frames.
- **A return's width is not known**: its files are what its sends bring, before the reverb or delay that spreads them (a mono vocal would make the reverb a point). Its cloud gets a nominal 20° each side, and the detail panel says its width is not known. Found while trying the stage; Y from its sends stands, marked "≈".
- **Muted tracks**: a track muted itself has a silent meter, so nothing says where it is now; the frame lists them (`mu`) and the stage keeps it hollow where it was last heard, marked "muted". A part cut by a mute above it or a solo elsewhere still meters its signal (step 5), so it is drawn hollow where its own meter puts it, marked "silenced", with the last Y heard (the spectra leave out what is cut, so its Y would read "?").
- Labels are HTML above each part, the louder first; a label that would overlap one already placed is left out (the selected part's never). Hover or tap shows the detail panel: kind, where heard, width, level against the mix and in dB, spectral centre, and what each mark means.
- The toolbar: All / chosen, Undo and Redo of the choices (the same commands as the debug page), the camera presets (3D, Top, Front; drag, wheel and pinch), the "Hide under" slider (kept in the browser), Tracks (the debug page) and About.

Measured (band fixture, the whole mix, playing; in-app browser):
- **Cost per screen frame: 1.0 ms median, 2.5 ms p95** (120 frames in a row, `rfvStage.bench`); 31.9 ms once, the first frame compiling its shaders. The frame rate a hidden or background browser pane gets (0 to 2 a second here) is the browser's throttling, not the page's: no long task was seen.
- Positions as the frames say: Gtr 1 at 17.2° left and Gtr 2 at 17.3° right, the synth pad "?", the returns "≈", the shaker hidden where it is silent.
- Solo on the vocals: the other nine parts hollow and marked "silenced". Chosen Drums with three of its tracks: Drums open in its shell. "Hide under" at 20 dB: the lead vocal, 21 dB under the loudest part, left out. Undo on the stage: back to the whole mix. Stopped: dimmed, "Stopped: the stage as last heard". A muted track kept hollow, "muted". The font Arial; About opens.

Found and fixed on the way:
- The engine's track lists in the frame (`hm`, `ae`, `ha`, `hi`) are numbers; the stage looked them up as strings, so no part was ever marked silenced.

### Step 8 reviewed and revised (2026-10-14)

The owner looked at the stage on OurGoodWolf and found it good. The review (three lenses) sampled the stage page in two sessions in temporary tabs: the band fixture with the Vocals bus soloed half way, and 120 tracks playing at once. The owner chose every recommendation:

| | Found | Done |
|---|---|---|
| L1 | A part cut by a solo was drawn from its own meter against the master, which then holds only the soloed part: soloing the Vocals took the master from −9.8 to −16.9 dB, and the cut parts jumped forward and swelled (Bass −10.3 → −1.9 dB, Synth pad −5.1 → +3.7, bigger than the soloed Vocals), hiding the Vocals. Its own meter is also before its bus's fader and pan. | A cut part stays hollow where it was last heard (place, level, height), as a muted one did. The frame lists the stage objects cut now (`oc`: a mute of their own or above them, or a solo elsewhere, whether they sound or not), so a cut part no longer blinks out when its music rests. Checked: during the solo every cut part kept its level exactly (min = max over 57 samples), the Vocals nearest. |
| L2 | "?" ("its sound does not come from files") showed while files were still being read: at the start, after each change of view (no Y for a moment), and 11 of 120 parts in the crowded session. A bus or a return reads nothing itself, so its share read was always 100 %. | "?" only once what a part rests on is read; before that only "reading". The engine carries the share still to read through the routing by power (`SP.compose` and `SP.combine` return it; `spectrum_logic` checks a bus at 0.375 from inputs half read, unread and with no files); a return reads as its sends. Without Y for a moment, the last Y stays. The debug page follows the same rule. |
| L3 | A part never heard since the page opened (muted before, or under a folder muted before playback, whose meter is silent) was left out without a word. | After 3 s of playing, the note names what is not drawn and why: "Not drawn, not heard since this page opened: Shaker (silenced)." |
| L4 | Depth spans 30 dB under the mix while "Hide under" keeps 40 dB under the loudest part (about −43 dB against the mix on the band), so parts between pile up at the back rim: 8 % of the band's samples. | Kept (the owner found OurGoodWolf good); to look at again on a second real song in step 10. |
| L5 | A frame could meet a newer graph with the same number of objects for one poll. | A frame is used only with the graph of its own version (`gseq`). |
| L6 | Stopped after a switch to another project, the note said "the stage as last heard" with nothing drawn. | The note asks whether anything is drawn now. |
| F1 | The page's cost grew with the number of parts, from the labels: 120 parts took 15–21 ms a frame (p95 18–25 ms; 1.0 ms with the labels hidden), past the 16.7 ms of 60 frames a second. Each label was moved and then measured, so the browser laid the page out once per label. | A label is measured only when its text changes, all in one go, and moved by a transform. 120 parts: 0.7–0.9 ms a frame in median, p95 1.2–1.5 ms, the camera turning so every label moves (`rfvStage.bench`); in the page's own frames 0.6 ms median, p95 1.7 ms, the largest (12–17 ms) when a new graph brings 120 new labels at once. |
| F2 | Checked, no gap: the whole-mix reference worked with the master muted in the tests (the master's meter reads before its mute, known since step 5); the dark theme reads well. Touch and pinch were not tried (no touch device). | none |
| U1 | The frequency post stood in front of the floor's left corner, the side the 3D view looks from: at 1024 × 768 its 200 Hz, 1 kHz and 5 kHz labels began left of the window. | The post stands at the back right corner; at 1024 × 768 and 800 × 600 every guide is in view in all three views. On a phone held upright the stage itself spilled off both sides: the view now keeps the width of a 4:3 screen there, and the note and About stand below the header however many rows it wraps to. |
| U2 | The distance rings carried no numbers. | Rings at 0, −10, −20 and −30 dB against the whole mix, labelled. |
| U3 | The guides' labels were placed before the parts', so a part by a speaker lost its name. | Parts first, guides where room is left. |
| U4 | Nothing told how many parts "Hide under" kept off the stage. | "(n hidden)" beside the slider. |
| U5 | A cut return was a large wire cloud. | A fainter cloud, no wire. |

Not done now: the suite run of 2026-10-14 in which REAPER stood still for 5.5 minutes (14:33–14:38) at the first step of `engine_readonly`, while that test saved its own project in a temporary tab and no test engine ran; the owner was away. It touched neither the engine nor the page, which never save or open a project, so it is left for step 10 (long runs), which will record the engine's longest cycle with its time so that a repeat shows whether the engine was running in it.

## Step 9 research (planning, 2026-10-14)

- **Meters say nothing while stopped.** On the owner's engine (OurGoodWolf, stopped): no track meter and no master meter above the −100 dBFS floor. The −86 dB the owner's master showed in step 5 comes from FX that run while stopped, and only while REAPER's audio device is open (`audiocloseinactive` closes it when REAPER is in the background). So while stopped the stage needs a source other than the meters.
- **The files through each track's fader and pan, without meters** (scratchpad `research9_model.lua` and `.py`: the band fixture's files read in full through the step-7 map in 8.8 s, 24,960 windows, each track's in-band power per section through its own pan matrix and fader, against the rendered stems after FX):
  - Tracks without FX: the same as their output up to one constant (the analysis's scale), median 0.18 dB per section, p90 1.89 dB; the larger errors are parts that are nearly silent there (the shaker at −74 dB), which the stage hides.
  - Tracks with FX, their FX gain not known: median 2.98 dB, p90 7.36, max 10.0 (the band's second guitar +9 dB, the piano +7 dB). On the owner's mix every track with files has FX.
  - With each track's FX gain learned on the other sections (leave one out): median 0.47 dB, p90 2.35 (tracks with FX 0.79 and 2.35); the worst, the hi-hat in the shaker section, 4.1 dB.
  - X from the files and the pan matrix: 0.00° median and p90; the piano, through its widener, 3.6° at worst.
- **The map's speed**: the owner's engine read the whole song for 37 tracks (127,153 windows) within its first 30 minutes. At the engine's ~140 windows a second, one window a block (a coarse pass) is about 25,000 windows, 3 minutes.
- **Sections in real projects** (the owner's 17 `.rpp` files read as text): OurGoodWolf (the version being mixed) has two regions, Intro and Verse 1; its other versions only two notes as markers ("Check Gain Vox", "Check Gain INS"); Brauerize and the Tiki Horea template have one region over the whole song (0–249 s, a render region) and twelve plain markers naming the sections (intro, verse 1, prechorus 1, chorus 1, …, end); the rest none. The rule agreed on 2026-10-10 (regions, else `#` markers) would give Brauerize one section.

### Decisions for step 9 (owner, 2026-10-15: every recommendation)

1. **Stopped, the stage comes from the files at the edit cursor**, through each track's fader, pan and buses as they are now (a fader moved while stopped shows at once), times each track's FX gain learned while it played: learned at that place ("measured"), the track's median elsewhere ("model"), none where it never played ("FX not known").
2. **Live while stopped**: only a track armed with monitoring takes its meter (step 5's estimate); every other part comes from the model, so dither, FX noise and reverb tails are not taken for parts.
3. **A track without files** (a virtual instrument) gets the power it measured at that place when played, else its median, else "?" with no level guessed.
4. **Sections**: regions, else `#` markers; a region over 90 % of the song or more is not a section (a render region); the page setting regions / `#` markers / all markers / none stays, kept in `.rfv.json`; "all markers" leaves out a marker at the song's end and sections under 2 s.
5. **Seeing a section**: a list in the header, "At the cursor" or a section; a section shows its average stage, marked measured or model, with the share played.
6. **Step 9 in two**: 9a the stage when stopped (1–3, the coarse-first map, the page no longer dimmed), 9b sections (4–5), each with its gate and review.
7. **9a's gate**: the engine follows a cursor move within one frame (0.1 s); X ≤ 1° median per section; Z ≤ 1.5 dB median per section once the section has played (elsewhere reported, marked "model"); noise while stopped is not taken for a part, a live part still shows; the read-only gate passes.
8. **The map's budget stays 1.5 ms a cycle** while stopped (a coarse pass over the owner's song takes about 3 minutes).

### Step 9a as built (2026-10-15)

Files:
- `engine/rfv_learn.lua` (new): what playing teaches, per key (a track's FX gain, a bus's, the power of a track without files) and per 0.5 s block, in dB.
- `engine/rfv_heard.lua`: `HD.fill` (a bus's output from its inputs and its learned FX gain), `HD.degrade` and `HD.carry_basis` (where a level comes from), `HD.propagate` with fixed gains.
- `engine/rfv_spectrum.lua`: `SP.SCALE`, the factor from a stats vector's powers to mean squares.
- `engine/rfv_ymap.lua`: the coarse pass.
- The engine: `stopped_model`, `learn`, every track read (the stage's first), returns as buses, frame fields `sm` and `ob`, `ym.coarse` and `ym.learned`.
- The pages: the stage while stopped, the marks "model" and "FX not known", "Level from" in the detail panel, the note; the debug page says when its numbers come from the model.
- Tests: `stopped_logic` (method), `stopped_live` (band, against the truth); `spectrum_logic` checks `SP.SCALE`; `engine_load --set stopped=1`.

How it works:
- **Stopped, each track's own output comes from its files at the edit cursor** (the next 2 s, as Y's readout) through its fader, pan and every volume stage as they are now, divided by `SP.SCALE` (3N²/16 for 2,048-point Hann windows; a sine of peak 0.25 reads −12.04 dB, as it should) and multiplied by its FX gain as learned. A bus's output, a return's and the master's are worked out from their inputs (`HD.fill`), with their own learned FX gains, and carried to the master as while playing. So the frame keeps its form: `a`, `h`, `o` and `ma` hold the model's numbers, and `sm` is 1.
- **Learning while playing**: after 2.5 s of playing on without a jump (the meters' 2 s window must hold what the files hold), about five times a second, each track with active FX learns its FX gain (its meter's power over its files' through its fader and pan, over the meters' 2 s, when at least half of it is read); a track without files, the power it had before its fader while it sounded; each bus and return, heard()'s FX gain (not while anything is soloed). A sample goes to every 0.5 s block it covers; a block holds the mean of its samples, then moves by 1/20 of each new one, so a part played again after a change follows within a few passes. Kept in memory while the engine runs (since the review also in a file per project, below). A track whose FX chain changes (count, on or off) forgets what it learned; a parameter moved inside an FX is not seen until the part plays again.
- **Where a level comes from**: per track the shares of its output learned here, elsewhere in the song, never (a track without FX: known); a bus mixes its inputs' by power and degrades them by its own gain's; each heard level by every bus gain on its way; each stage object by its tracks' heard powers (`ob`). The master's gain is in every part and in the mix alike, so Z does not rest on it.
- **Live while stopped**: a track armed with monitoring keeps its meter (step 5's estimate); every other meter is left aside while stopped, so a tone or noise from FX that run while stopped is not a part.
- **A track without files**: where it has a MIDI item at the cursor, the power it had there when it sounded, else its median; never heard, no level (not drawn), as decided.
- **On the page**: the note says where the stage stands and how much of it rests on FX measured there (here, elsewhere in the song, not heard yet), and names a virtual instrument left out for want of a level; a part's own mark ("measured", "model", "FX?") shows only where it differs from most of the stage. Tried first with a mark on every part: before any play every label carried "FX not known", and the longer labels hid two names (Drums, Gtr 1). The detail panel always tells, under "Level from".
- **Every track is read** (the stage's tracks first): stopped, the master's level, against which every part's Z stands, comes from the whole mix. Y is still worked out for the stage's tracks only.
- **The coarse pass**: after the readout around the position, one window in every block of the song for every track, then every block filled.

Measured:
- Band, `stopped_live` (the cursor stepped through the song in 2 s steps, each step's first frame; per section against the rendered stems): never played, own Z 2.06 dB off in median (p90 6.31; without FX 1.09, with FX 3.90), X 0.00° (p90 1.61); the synth pad, never heard, no level. After the song played once (3,038 blocks learned): **Z 0.46 dB in median (p90 1.56, max 3.09; without FX 0.28, with FX 0.67), X 0.00° (p90 1.20, max 3.52)**. The gate: Z ≤ 1.5 dB, X ≤ 1°.
- Following the cursor: the first frame at the new place came 0.064 s after the move in median, 0.096 s at most (94 moves). A fader moved by −6.02 dB while stopped: −6.0 dB in the next frame, 0.092 s.
- While stopped with the audio device running: a tone from an FX at −40 dB on a track not armed was not a part; an armed, monitored input at −82.7 dB (the interface's noise) was.
- 224 tracks, the whole mix: stopped, a frame cycle took 2.1–2.4 ms (playing 1.95–2.04), whole ticks 1.88 ms median, p95 3.0–3.2 (playing 1.84–1.86, p95 2.8–3.0); but the map then reads 29–38 windows a second (playing 81–94), the frame leaving it little of the 2 ms: a lighter frame at that size is step 10's.

### Step 9a reviewed and revised (2026-10-15)

The owner tried 9a on OurGoodWolf. Their engine's frame, read through the web interface, showed every part with the same basis, 32 % measured here, at 0:22, right after playing there. The owner chose every recommendation:

| | Found | Done |
|---|---|---|
| L1 | The shares of a level measured here were multiplied along the buses as if independent: on the owner's mix every track passes three or four buses with FX (sub, group, premaster), each 75 % known there, and 0.75⁴ ≈ 0.32. All of them are learned in the same passes, so they are known at the same places. Also, a bus carrying the whole mix (the owner's premaster) is in every part and in the mix alike, so Z does not rest on its gain. | `HD.degrade` takes the worse of the two stages at each place (four stages at 75 %: 75 %); a bus with the role mix bus is left out of the bases, as the master. |
| L2 | Learning starts 2.5 s into playing (the meters' 2 s window), so the first block where playing started is never learned, and stopping takes the edit cursor back there (REAPER's default, seen in a probe): on the band, played from 10 s and stopped, the stage at 10 s read 0.56–0.75 measured. | A block not learned takes the nearest block learned within 1 s (`LN.NEAR`): an FX gain moves slowly. On the band, played 6 s from 50 s and stopped: every part measured there. |
| L3 | An FX switched on or off, added or removed while stopped kept its old learned gain until the song played, since the chains were looked at only while learning. | Each track's chain is fingerprinted whenever the state counter moves, playing or stopped; a changed chain forgets what it learned, and a track whose FX are all off is exact. Checked: Gtr 1's FX off while stopped, its level exact; on again, "FX not heard". |
| L4 | A setting inside an FX moved while stopped is not seen. | Kept; the About panel says it shows once the part plays again. |
| F1 | Accuracy is measured on the band (REAPER's own FX) only; the owner's mix has third-party FX on every track, and opening it in a temporary tab could raise plugin dialogs. | Measured with the owner (below): the model missed what the meters heard by 2.3 dB where it had learned everything, 6.3 where it had learned 58 %; fixed by keeping what the meters measured. |
| F2 | Checked, no gap: paused, REAPER moves the edit cursor to where it paused, so the stage stands there; stopped, the cursor goes back to where playing started. | none |
| U1 | What playing taught was lost when the engine stopped: each session, "FX?" everywhere until the song played again. | Kept per project in REAPER's resource folder, `Data/ReaperForVisual/learned/<section>/<project>-<hash of its path>.txt`, never beside the project: written when playing stops and when the engine stops (through a .tmp file), read when a tab is first seen; a track whose FX chain differs from the one the file knew starts afresh. The band's whole song: 38 KB. Checked: engine stopped and started again, 3,038 blocks back, every part measured at 12 s. An unsaved project keeps it in memory only, and so does a project in the system's temporary folder for the user's engine (it follows the tests' temporary tabs and had kept files for nine fixtures; a test engine writes under its own section, which the harness empties). |
| U2 | The About panel said nothing of the stage when stopped. | One paragraph: the edit cursor, the files through the faders as they are now, FX as measured while playing and kept for the next session, "model", "FX?", a setting inside an FX. |
| U3 | In the first minutes the parts come in one by one while the files at the cursor are read, without a word. | The note adds "The files around the cursor are N % read." |

**F1, measured with the owner (2026-10-15).** A read-only recorder of their engine's frames (scratchpad `f1_recorder.py`) while they played 22–67 s of OurGoodWolf and stopped at 22, 33, 41 s and at places that had not played; stopped at S, the stage against the frame that played S + 2 s (the meters' 2 s over the same seconds). The parts against the mix were 2.3 dB off in median at 22 s (all learned there), 6.3 at 41 s (58 %), 3.0 overall (p90 12); on the band the same measure gave 1.0. The worst were close drum mics (snare 1 −10.9 dB, hi-hat −7.0) and, at 41 s, the lead vocals.

Why, measured on the owner's stems (scratchpad `sampling_bias.py`): the map reads 43 ms windows every 0.1 s, 43 % of the time, and a drum hit falls between them more often than not. Per 2 s against every sample, the snare read 2.2 dB off in median read in full, 3.7 (p90 14.7) with 3 windows of 5 (what playing reads when the map lags: on the owner's machine it had read 55 % of the seconds behind the play position, in median), 8.0 with 1 of 5; the kick 1.9 and 9.8; bass, piano and vocals 0.1–0.3 in full. A gain learned as the meter over a sparse reading of the files, then applied to a full reading, carries the difference. Windows placed at random offsets in their slots changed little (the snare read in full 2.35).

The fix (the owner's choice): **where the song played, the stage when stopped is what the meters measured there**. Every track's power is learned per block as its meter measures it, before its fader and pan (taken out through its pan matrix), and is put back through its fader and pan as they are now, so a fader moved while stopped still shows at once; the files times the learned FX gain only where nothing played. Learning no longer waits for the files to be read. A track whose items change (moved, muted, cut) forgets the powers it was measured at; the learning file keeps a fingerprint of each track's items for the same check after a restart. Levels average as powers: averaged in dB, the band's backing vocals, which come and go, read 4 dB low (the first try). The band, after the fix: stopped where it played against the meters over the same 2 s 0.90 dB in median; against the rendered truth per section 0.94 dB (the meters' own accuracy, step 5: 0.93; the files with learned gains had read 0.36 on the band, whose FX are REAPER's own). Measured again with the owner after the fix (they played 22–59 s, then stopped at ten places in it): the parts against the mix 0.50 dB off in median, p90 1.50 (before the fix 3.0, p90 12); every place 0.3–0.7 dB. A frame that played only 2 s after playing started is left out of the comparison: its meters still rise from silence.

Measured after the revision (`stopped_live`, band): Z 0.36 dB in median per section after one play (p90 1.62), X 0.00°; the cursor followed in 0.062 s median, 0.107 s at most. Suite 28/28; read-only gate 600 s PASS. The F1 recorder, checked on the band: stopped at a place that played, against the meters over the same 2 s, the parts against the mix 1.0 dB off in median (p90 2.9), most of it the meters' own error per 2 s window.

### Step 9b as built (2026-10-15)

The decisions are those of step 9 (4 and 5); built without a planning stop of its own.

Files:
- `engine/rfv_sections.lua` (new): the sections from the regions and markers (`SC.build`, pure; `SC.read`).
- The engine: `stage_model` (step 9a's stopped model over any range, blended for a section), `section_stage`, `sections_tick`, the ExtState key `sections`, the page command `sections`, the graph's `view.sections`; `object_tuples` (Y and width per object, shared with the spectra); `ym.cycle_ms.section`.
- The stage page: a list in the header ("At the cursor" and each section with the share measured) and where sections come from; the note for a section.
- Tests: `sections_logic` (the rules on the kinds of project found among the owner's), `sections_live` (band, four regions, against the truth per section); `engine_load --set regions=N`.

How it works:
- **Where sections come from** (`sections.source` in `.rfv.json`, unchanged from spec v0): `"regions"`, the default, is regions, a region over 90 % of the song or more being a render region (Brauerize's 0–249 s "song"), and the `#` markers when no other region is; `"markers#"`, `"markers"` (a marker at the song's end and a section under 2 s left out) and `"off"`. Existing files carry `"regions"` already, so they get the default the owner chose. Brauerize needs "every marker", one choice on the page.
- **A section's average stage**: step 9a's model over the whole section, blended: for each track, what its meter measured in the section for the share of it that played, its files with the learned FX gain for the rest; the faders, pans and buses as they are at the section's middle, mute and solo as they are now; Y and width from the files over the section through the same routing. The share measured is the stage's, by power.
- **When**: the list again whenever the state counter moves (a marker or region added, moved, renamed), the choice changes, or every 2 s. The stages only while a page is open (`page_seen`), one section at most every 0.5 s, on a tick with no frame and no spectra work, the sections in turn; published once a second as `sections`: `{ gseq, tab, source, used, list: [{ name, a, b, played, ma, o, oy, ob, nl }] }` (the stage fields once worked out, for the graph version `gseq`).
- **The page**: the list "At the cursor / Verse 1 · 0:22–0:40 · 100 % measured / …" and "Sections: regions / # markers / every marker / none" (a command, kept in `.rfv.json`). A section chosen stays shown while the song plays (the note says "At the cursor" shows it live); a section that no longer exists gives the cursor back.

Measured:
- Band (`sections_live`): the four regions listed; never played, none of them measured (Z 4.3 dB off the truth in median: FX not known); after the song played once, 97–100 % measured, **Z 1.04 dB in median per section (p90 2.04), X 0.04°** against the truth heard per section. The source changed from the page: none, every marker (the band has none), regions again; an unknown one refused.
- On the page (band, played 2–60 s): Verse 2 94 % measured, Backing vocals 100 %, Shaker 11 %, Ending 0 %, each with its note; marks only where a part differs ("measured" for the shaker, which has no FX, in a section that never played).
- 224 tracks, eight sections, a page open: one section's stage took 3.4–6.3 ms; worked out on every spare tick it raised whole ticks to 2.3–2.8 ms in median (p95 5–6), so at most two a second: playing 1.91 ms median, p95 3.8 (without sections 1.84 and 2.8–3.0); stopped 2.17 and 4.3. A lighter whole cycle at that size is step 10's.
- Suite 30/30. The read-only gate (600 s) now has two regions and a page open all along: both sections worked out, the state counter, dirty, undo and redo unchanged.

### Step 9b reviewed and revised (2026-10-15)

Reviewed on the owner's OurGoodWolf through their engine's ExtState (read-only), right after they restarted it: Verse 1 (22-40 s, 98 % measured) against the meters recorded while it played (`f1_ogw2_clean.jsonl`), the parts against the mix 0.19 dB off in median (p90 0.52, max 0.95, n = 20). The map was still reading (coarse 2-14 %), which showed L1 and L2. The owner chose every recommendation:

| | Found | Done |
|---|---|---|
| L1 | A section's stage rests on files still being read in the first minutes, and the page did not say so: on OGW Intro went from 22 to 23 parts drawn and its mix from -9.5 to -10.2 dB as the coarse pass went from 2 to 12 %. | The engine publishes `read` per section (the share of the files its stage rests on read at least once, each track as one); below 99 % the note adds "Its files are N % read: parts may still be missing, and levels and heights may still move", or for a section measured at 90 % or more "heights and widths may still move". Band: 25 % a few seconds after the start, 100 % 45 s later, then the sentence goes. First weighed by the share of each level that comes from files: checked on OGW, Verse 1 (98 % measured) read 0 % with every height still on unread files, and the note spoke of missing parts; now each track counts as one and the wording follows the share measured. |
| L2 | Every label read "reading" in a section: the share read of a long section stays low for as long as the dense pass takes (over 15 minutes on OGW); on OGW all 30 objects read 0.11-0.33. | A section's Y counts as read once the windows read are as many as a 2 s readout's (`min(1, share x length / 2 s)`); the mark says "its files in this section are still being read". |
| L3 | A section played in part took its files over the whole section for the rest, the part that played included. | The blocks that played (as `LN.here` counts them, a learned neighbour within 1 s included) as the meters measured them, the files over the other blocks only; a track's basis between them by power. |
| L4 | The section on the page waited its turn: with twelve sections, a fader showed up to 6 s late. | The page writes the section it shows to `page_sect` every 2 s and when the choice changes; the engine works it out first whenever its stage is a second old and publishes at once; the page reads sections twice a second while one is shown. Measured (`sections_model`): 0.87 s from a fader move to the published stage. Two stage pages showing different sections take turns (the last writer goes first). |
| L5 | Faders and pans are read at the section's middle: automation inside a section is not averaged. | Moved to step 10 (OGW has no such envelope). |
| U1 | Parts muted or cut by a solo now were missing from a section without a word (the cursor's stage keeps them hollow). | The note names them: "Left out, muted or cut by a solo now: Shaker (muted), Bass (muted)" (band). |
| U2 | Section times read "0:22.0-0:40.0", more exact than a region's edges are. | Whole seconds in the list and the note: "0:22-0:40". |
| F2 | "# markers" and "every marker" were tried in the logic test only. | `sections_model` (new) runs both on markers in a live project. |
| F3 | A section never played rests on the files alone (band: 4 dB off the truth, FX not known). | Kept; the note says so. |

Found while fixing, fixed with them:
- **Silence was left out of the files' level.** A block whose windows are all silent, or that has no item, was not counted, so a part that plays in a quarter of a range read as loud as where it plays (+6 dB). `YM.stats` now also returns the windows read there, silence included, and the level is the power over them; the same for the FX gain learned while playing. The stopped stage at the cursor is concerned too (step 9a): on the band, never played, tracks without FX 1.21 -> 0.95 dB off the truth in median per section. A block read and silent is told from one not read yet by the windows read.
- **"% measured" counted parts with no FX as measured.** The basis calls a part with no FX known exactly from its files, so a section never played read "100 % measured" on a project without FX. A section's `played` is now the share its meters measured (`model.meas`, carried through the buses in the same pass as the basis: a pass of its own cost 0.3-0.6 ms at p95 on 224 tracks); the marks per part are unchanged (their text says "or from its files, where it has no FX").

The owner then chose to fix the two left (N1, N2):
- **N1**: the cursor's note had the same fault (step 9a): stopped where nothing played, a project without FX read "the stage as measured here when it played". The frame carries `mp`, the share its meters measured; the note says "measured" by it, and "with the FX measured elsewhere" only where some of the level rests on such FX. Checked on a project without FX: never played, "the stage from the files at the cursor ...: this place has not played yet" (`mp` 0); after playing 12-20 s, at 12 s, "as measured here when it played" (`mp` 1.0).
- **N2**: the section list was cut at 260 px ("49 % meas"); it now takes up to 400 px, the screen's width less 32 px on a phone.
- Cost, stopped, 224 tracks, whole mix: whole ticks 1.85-1.87 ms in median, p95 3.4-3.6 (without the measured share 3.2-3.5; with it in a pass of its own 3.8-4.0).
- Suite 31/31 again. In that run the coarse pass stood at 98 % when `stopped_live` began its never-played sweep: Room 2 was not read yet in two sections (no level in one, 19.8 dB low in the other), the case the read share in the note now tells.

Measured after the revision:
- `sections_model` (new, a 30 s project known by arithmetic): never played, a part playing a quarter of a region 6.02 dB under where it plays (-0.08 off) and one 10 dB lower in its second half 2.60 dB under its loud half (exact); after playing only the quiet half, -0.10 dB off (the files over the whole region: -2.0, worked out); 33 % measured; regions, `# markers`, every marker and back.
- `sections_live` (band) after one play: Z 0.98 dB in median per section (p90 1.92, max 2.66; before 0.94, 2.05, 10.93); never played 3.96 (p90 7.35, max 10.20; before 7.57, 11.43). `stopped_live`: never played 2.09 (before 2.14), after one play 0.90 (0.91).
- Suite 31/31.
- Seen while testing: REAPER's meters read peaks, and the crest correction (step 5) was fitted on the band's instruments: white noise reads 6 dB over its files, a steady sine 1.5 dB under. Tests judge the meters on music only.

**Acceptance on OGW (2026-10-16).** Read through the owner's engine (read-only) and with two fader moves of theirs made by the MCP tools (19_LeadVox1 to -6 dB and back to 0.0, checked). Seen: Verse 1 (98 % measured) "Its files are 71 % read: heights and widths may still move"; the cursor where nothing played "... with the FX as measured elsewhere in the song: this place has not played yet" (`mp` 0); at 0:00, played, `mp` 1.0. Found:
- **What playing taught was lost when the project was opened again.** After the owner's REAPER session restarted, Intro and Verse 1 read 0 % measured (100 and 98 before), 14 of 30 parts drawn (26), 5,672 blocks learned (10,270); the learning file still held the measured powers of 20 tracks. The item fingerprint (`YM.fingerprint`, kept hashed in the file) held each take's source as `tostring()`, a pointer, and a project opened again gets new source objects (probe: `...1DD0` -> `...2140`), so every track read as changed and its measured powers were refused. The 9a restart test restarted the engine only. Fixed: a source is named by its type and file (by its length too at first: offline it reads 0, see step 10b); `stopped_live` opens the project again before the restart (10,886 blocks back, every part measured here); `spectrum_logic` checks the fingerprint holds the file and no pointer. A learning file written before keeps the old fingerprints: the song is played once again.
- **Half of the owner's map was dropped at once** (coarse pass 85 -> 48 %, the cursor's files 100 -> 33 %), at the first MCP change, the one that writes the MCP tools' backup copy (`Main_SaveProjectEx(0, path, 0)`); the second change did nothing of the kind. Not reproduced: a copy saved, media beside the project or not, and media set offline and online again, left sources and fingerprints as they were. The map now counts what it drops (`ym.resets`, `ym.reset_last`: the last track's name) for the next time.
- After the fix, the owner's engine restarted and 0-42.5 s of OGW played again: Intro and Verse 1 100 % measured, 97-98 % read, 26 and 24 parts drawn, no label "reading", the learning file written with the measured powers of 20 tracks; `ym.resets` 0 throughout. 19_LeadVox1 to -6 dB while stopped: both sections followed in 0.8 s, by exactly -6.0 dB (Intro -18.0 -> -24.0, Verse 1 -12.9 -> -18.9); back to 0.0 dB. Muted: the note on Verse 1 "Left out, muted or cut by a solo now: 19_LeadVox1 (muted)"; unmuted. At 0:00 "the stage as measured here when it played". The fader, the mute and the edit cursor (2:30) as they were, read back.
- Suite 30/31 then `axes_live` 1/1 alone: in the suite run its playback was stopped from outside at 71 s (the owner restarting their engine meanwhile).

**Step 9b closed 2026-10-16.**

### Step 10 research (2026-10-16)

The roadmap's step 10 gathered seventeen items over the reviews, against a price of 1.5 h. What is known now:

- **Media offline** (REAPER's "set media offline when not active", the owner's setting, which applies whenever they look at the page in a browser): a track's audio accessor read the same window, the same power, with every item set offline (action 40100) as online; the map read -12.0 dB over 2-4 s either way. Offline media does not blind the map. (Probe `probe_offline_read.lua`.)
- **Thousands of items**: `YM.fingerprint` costs about 20 us an item (3,000 items on 60 tracks: 59 ms for every track; 50 items 0.65 ms). The map fingerprints one track at a time within its budget when the state counter moves; the learning fingerprints every track at once when it first meets a tab: one 59 ms stall at 3,000 items.
- **Cost now**: OGW (48 tracks, 37 read), stopped: whole ticks 1.85 ms in median, p95 3.4, max 8.5; the frame's own cycle 1.9 ms; the map 42 windows a second. 224 tracks, stopped: ticks 1.85-1.9, p95 3.4-3.6, frame cycle 2.2-2.6 ms; playing 1.91, p95 3.8. A tick is the frame plus the map, which takes what is left of 2 ms by design (step 7): the step-5 target "ticks near 1 ms" predates the map and now reads as the frame's own cycle.
- **Stopped, the frame works the whole stage out every frame** (30 a second) though nothing may have changed: most of the stopped cycle, and why the map reads 29-42 windows a second stopped against 80-94 playing.
- **The learning file** at play stop: OGW 110 KB in 34 ms, band 145 KB in 25 ms, one stall each time playing stops.
- **Unexplained once**: half of OGW's map dropped at the MCP tools' first change (step 9b acceptance); `ym.resets` now counts drops.

### Step 10a as built (2026-10-16)

The owner chose every recommendation of the step 10 plan: 10a (holding up, lighter) first, 10b (a second song) after; the cost gate read as the frame's own cycle, at most 1 ms in median playing and stopped at rest, with whole ticks within their 2 ms budget (median) and 3.5 ms at p95; the hour-long run when the owner is not using REAPER; the second song chosen at 10b.

- **The stage when stopped, worked out only on a change** (`stopped_key`, `same_key`, `STOP_REFRESH` 2 s, `NEAR_REFRESH` 0.3 s). A fader, a pan, a mute or a solo set by a script, or a fader by a control surface, does not move the project's state counter (measured; a pan and a mute by a control surface do, the edit cursor does not), so the key reads every track's fader, pan and width and the master's (224 tracks: 0.08 ms), with the mutes and solos the frame reads anyway, the cursor, the state counter, the graph, the stage and the pan defaults; the files read around the cursor count every 0.3 s at most (at 224 tracks they read on for over a minute after a start, and each window read made it work the stage out again); every 2 s anyway (a send or a pan mode set by a script). A track armed and monitored keeps it worked out every frame. The cost figures carry `stopped`, `reused` and `why` (what made it work the stage out).
- **The cost figures** (`frame.cost`) also carry `frame_ms_med` and `frame_ms_p95` (the frames' own cycles), `max_ms`, `max_at`, `max_kind` (the longest tick since the start, when, and what it did: graph, frame, gather, finish, section), `gap_max_ms`, `gap_max_at`, `long_gaps` (REAPER held the engine for over 0.25 s) and `mem_kb` (the engine's Lua memory).
- **The crest coefficients** asked once a frame, not once per track (`MT.crest` keeps its last answer): the meters' part of a playing frame at 224 tracks 0.79 -> 0.45-0.55 ms.
- **The learning file**: read keeping each key's blocks as text, parsed only for the keys taken (`LN.load_text`; parsed into tables first, the owner's 110 KB took 42 ms at the engine's start); written when playing stops as a job a few keys at a time, 2 ms a tick at most (`LN.key_text`, `run_jobs`; the owner's file took 34 ms at once), in one go when the engine stops. `ym.load_ms`.
- **The safety net lets go**: a track it took in as a source, silent for 30 s of playing, is what the routing says again (`net_release`, `NET_RELEASE`). Checked in `engine_roles`: the JS tone switched off while playing, after 30 s "ignored", none held.
- **`meter_live`**: a part stopped two seconds ago counts as silent under -90 dB too (2 of 14 suite runs read -96 and -98 dB: a refresh that came early fell less than the decay step and was taken for a peak on the tail; far under anything the stage shows).
- **`endurance_test`** (new): the band in a loop for an hour in five-minute blocks, each recording the figures above and doing one thing in turn (a track added, deleted, playback stopped for a block, a second tab for 20 s, playing on); gate: no error, Lua memory and tick median in the last third within 25 % of the middle third's.

Measured:
- Stopped, 224 tracks, the whole mix: the frames' own cycle 2.2-3.0 ms -> 0.86 ms in median (p95 2.8); whole ticks p95 3.4-4.0 -> 2.9 ms; the cursor still followed in 0.060 s (median), a fader in 0.073 s (`stopped_live`).
- 48 tracks (the owner's size): playing 0.51 ms (p95 0.96), stopped 0.22 ms (p95 0.75).
- Playing, 224 tracks: 2.0 -> 1.9 ms in median: mutes and solos 0.3, meters 0.45-0.55, heard 0.5, the rest formatting and publishing; about 8.5 us a track, so 1 ms there needs the frame's core rewritten. The owner's decision (2026-10-16, a): the 1 ms gate holds at a real project's size (48 tracks) and stopped at 224 tracks; 224 tracks playing stays at 1.9 ms, recorded.
- **The hour-long run** (`endurance_test --set minutes=60`, 2026-10-16): PASS. No error, the engine running throughout; Lua memory 3.5-6.6 MB with the collector's swing and no rise (middle third 5.9 MB in median, last 4.0); tick median 0.67 -> 0.51 ms (middle -> last third); frames 0.62-0.71 ms playing, 0.24-0.29 ms stopped; the longest tick 8.1 ms (a frame, at a stop); 4 gaps over 0.25 s in the hour (REAPER held the engine; the longest 913 ms at 2,766 s; REAPER's autosave is off, and the times are irregular: not found); the map dropped nothing (a track added three times made new entries, not drops); 10,934 -> 11,278 blocks learned (the loop's blocks capped, the added track's new). Opening the second tab stopped the band's playback (REAPER plays the active tab): the run covered both, the next block playing again.
- The learning file read the new way, on the copy of the owner's file with every key taken: 26 ms (5.5 reading, 20.7 parsing; before 45.5), once when the engine starts; written, 37.5 ms of work spread over about 19 ticks.
- A 6-minute try of the long run: no error; memory 4.1 -> 4.3 MB from the middle to the last third; stopped 0.27 ms a frame; a second tab opened: the longest tick, 12.5 ms (the graph built for it); one gap over 0.25 s (262 ms; another try had 991 ms once, at the loop's wrap).

### Step 10a reviewed (2026-10-16)

Logical, factual and user-oriented, after the hour-long run. The owner chose the recommendations:

| | Found | Done |
|---|---|---|
| G1 | The figures added for stalls and cost were in the frame's JSON only. | The debug page shows them: the frame alone (median, p95), and since the start the longest tick with when and what it did, how often REAPER held the engine over 0.25 s and the longest such gap with when, the Lua memory, the share of stopped frames reusing the stage; with the map, the learning's read and write times, the tracks read again. Seen with a test engine (48 tracks, stopped): the frame 0.25 ms, longest tick 6.7 ms at 0:00 (graph), held 0 times, 1.3 MB, 86 % reused. |
| G2 | A write of the learning that failed was kept silent (`T.save_err`). | In the frame's `ym.save_err`; the debug page says "writing the learning failed". |
| G3 | Four gaps over 0.25 s in the hour (913 ms at most), REAPER's autosave off, irregular times. | Kept: counted and timed now (`long_gaps`, `gap_max_at`). Seen also: with REAPER in the background, the owner's engine ran 12 ticks a second, 78 ms apart (31 in front). |
| G4 | Stopped, a send or a dual pan changed by a script shows within 2 s (by hand at once). | Kept (`STOP_REFRESH`). |
| G5 | The learning's new read and write not seen on OGW yet. | When the owner next starts their engine: the debug page shows both times. |

**Step 10a closed 2026-10-16.**

### Step 10b research (2026-10-16)

- **No second multitrack on this computer.** The owner's projects folder holds one full multitrack, OurGoodWolf (26 files; `RawAudio` is the same song, the band fixture is cut from it); SessionHoangDa has 3 files; ForRecV2, RandomBush and the templates in REAPER's media folder have none. A second song has to come from elsewhere.
- A free library of multitracks (Cambridge-MT, "Mixing Secrets") sits behind a bot check: not browsed (automated tools do not get past such checks); the owner can download one.
- What needs the second song: the crest model checked on other material (step 5's gate; fitted on the band, it put white noise 6 dB high, a steady sine 1.5 dB low: step 9b review) and the stage's depth against its hide threshold (step 8 review L4). What does not: faders and pans automated inside a section (step 9b review L5), on a fixture with envelopes; a meter refreshing faster than the engine reads (REAPER's meter setting, the owner's at the default 30 Hz; emulated p90 3.0 dB).

### Step 10b as built (2026-10-16)

The owner put a second multitrack on this computer (Actions, "South Of The Water", Cambridge-MT: 30 WAV files, 24-bit 44.1 kHz, 135 bpm; for education only, so the files stay there and nothing of them enters the repository; `L.env().media2`: `RFV_MEDIA2` or `tests/local_paths.lua`). The recommendations: b1 and b2 on it, b3, b4 left as a known limit.

- **The fixture `sotw`** (`tests/fixtures/sotw.lua`): 96 s from 1:30 (the stretch with most parts sounding, 17.8 of 30 on average, per 6 s RMS of every stem), 36 tracks: drums (kick trigger, snare compressed, overheads, toms and tambourine panned, a reversed cymbal, "sprinkles"), bass compressed, eight guitars spread wide on a bus cutting their lows, a widened piano, lead vocal compressed and brightened with its double 6 dB down, nine backing vocals spread, reverb and delay returns; regions Chorus 2 (0-36), Bridge (36-60), Break (60-66: piano and the reversed cymbal), Last chorus (66-96). REAPER's own FX only. Truth: `truth_build --set fixture=sotw` (36 own + heard stems in 31 + 183 s), `truth_stats`, `truth_share`.
- **b1, the meters on a second song** (`axes_live --set fixture=sotw`, two runs): X 0.02 deg in median (band 0.00); own Z 1.47 and 1.57 dB in median, p90 4.4-4.7 (band 0.93); heard Z 1.76 (band 0.92); Y 0.114-0.121 octave (band 0.12); width exact. The step-5 gate (Z 1.5 dB in median) holds at the edge. Worst: the kick, 15 dB loud in every section: a trigger, short clicks in digital silence, whose peaks the crest correction fitted on the band's miked kick (bleed between the hits) does not bring down far enough. And 3-7 track-sections with files but no Y (the reversed cymbal, the sprinkles, a guitar entering late): playing, the map read 49-50 % of the window behind the play position for 36 dense tracks (140 windows a second).
- **b2, depth against the hide threshold** (truth, every part heard above -60 dBFS against each section's loudest): band 25-37 dB from the loudest to the quietest part, none past 40; sotw 34-36 dB in three sections; in the last chorus the sprinkles, 49.8 dB under (-58.8 dB, a texture), the one part the default threshold (40 dB under the loudest) hides. The threshold holds on both songs.
- **b3, automation inside a section** (`matrix_over`, `send_over`, `AVG_POINTS` 8): a section's stage takes every pan matrix over the section, where an envelope or a VCA lead can move a track's volume, pan or width (or a send's): the matrix at 8 places across it, each entry the root of the mean of its squares (the powers it passes on average); else the matrix at the middle, as before. Checked (`sections_model`): a track at 0 dB, then -20 dB from 10 s, over a section of 0-20 s: -20.8 dB against -20.87 by arithmetic (read at the middle it would be -37.9).
- **Found while doing it, fixed: the media set offline dropped the map and the learning.** The owner's engine, with step 9b's fingerprint, dropped OGW's map 50 times in 33 minutes (`ym.resets`, last 25_BackingVox5). Measured: set offline (action 40100; REAPER's "offlineinact" does it whenever REAPER goes to the background), a source still reads its type and file but length 0, and the state counter moves, so every track's fingerprint changed, its blocks were dropped and what its meter measured forgotten. The source is now its type and file only (the item's own length and offset are in the fingerprint already). `spectrum_logic`: the fingerprint the same with the media offline; `stopped_live`: after the restart, media offline and online again, every part still measured here, no drop. A learning file written with the length in its fingerprints is read once more without its measured powers: the song is played once again.
- **b4, a meter refreshing faster than the engine reads** (REAPER's meter setting; the owner's is the default 30 Hz; emulated p90 3.0 dB): left as a known limit.

### Step 10b reviewed (2026-10-16)

The recommendations, applied when the owner said to go on:
- **R1, Z on other material**: kept for release 0.1 as it is, with its limit written down: about 1.5 dB in median per section on a second song (0.93 on the band it was fitted on), and a drum trigger (short clicks in digital silence) can read 15 dB loud. Refitting the crest model on both songs moves the error between them (emulated: the second song 1.79 -> 1.47 dB alone, the trigger still about +12). After 0.1: while playing, a track with no FX takes its power from its files (exact) where they are read, the meters only elsewhere; that removes the crest error where there is no FX to hide it.
- **R2, sparse parts with no Y while a dense project plays** (3-7 track-sections of 148 on the second song: the map reads half the window behind the play position for 36 dense tracks): kept, written down.
- Suite 29/31 then both alone 1/1: `axes_live` (band) failed on one sparse part with no Y (the shaker in the ending, read 58 %), which R2 keeps: the test now allows 3 % of the track-sections with files (one at least); `engine_readonly` saw the state counter move once at 42 s with a 309 ms gap (REAPER's media set offline and online when its focus changes moves the counter, measured in 10a; alone it stayed at 3).
- **Step 10 closed 2026-10-16.**
- OGW after the offline fix: the owner restarted their engine (the learning read in 12.9 ms, nothing dropped since); 0-42.5 s played again through the MCP tools: Intro and Verse 1 100 % measured and read, the learning written (111 KB, 23.4 ms of work spread over ticks), the edit cursor back at 0:00.

### Step 11 research (2026-10-16)

The owner's aim: installing and understanding it as easy as we can make it.

What a user goes through today, and what is known about each part:
- **ReaPack** is REAPER's package manager (a plugin file the user puts in `UserPlugins` once; many users have it). With it: Extensions > ReaPack > Import repositories..., paste an `index.xml` link; Extensions > ReaPack > Browse packages, right-click the package, Install. ReaPack registers each script marked as an action in the Action List; "Synchronize packages" updates. (reapack.com user guide.)
- **Where ReaPack puts files** (its source, `Source::targetPath`): a script under `Scripts/<index name>/<category>/<file>`; a web interface file under `reaper_www_root/<file>`, subfolders kept; one package may mix both, each file with its own type. So `rfv/index.html` lands where the engine opens it. An index named "ReaperForVisual" would install into `Scripts/ReaperForVisual/`, which on the owner's computer is the junction to the repository: the index needs another name.
- **ReaPack's API** is there for scripts (`ReaPack_AddSetRepository`, `ReaPack_ProcessQueue`, `ReaPack_BrowsePackages`, `ReaPack_GetOwner`: present in the owner's REAPER); so is `ViewPrefs` (open Preferences at a page). The page name for Control/OSC/web is not documented: to try in a test REAPER.
- **The web interface** is the step most likely to stop a beginner: Options > Preferences > Control/OSC/web > Add > "Web browser interface". It is a setting that opens a network port, so it stays the user's to make; the engine can make it easy (say what to click, open Preferences there). Today the engine only prints a line in the ReaScript console. A page on the same computer works whatever Windows' firewall says about the port.
- **The first page**: a project never set up shows an empty stage and a line of text ("Nothing is chosen yet..."); the buttons that fix it are in the header.
- **Names in the Action List**: "Script: ReaperForVisual.lua" (start and stop) says little; the six view actions are named for what they do.
- **Platforms**: the engine opens the browser on Windows, macOS and Linux; everything was tested on Windows with REAPER 7.82.
- **A clean install, tested for real**: a copy of the installed REAPER (158 MB) in a folder of its own with a `reaper.ini` runs portable, with its own resource folder; ReaPack's file copied into it; the index served from this computer. Unlicensed, it opens with the evaluation reminder; its audio must be "Dummy Audio" so it never takes the owner's Focusrite (ASIO, `[audioconfig] mode=3`) from their REAPER; its web interface on another port than the owner's 2307. The value for Dummy Audio in `reaper.ini` was not found: the owner sets it in the test REAPER's Preferences at its first start.
- The repository has no commit yet; GitHub's command line is not installed; `.markdown-collab/` (an editor's) is untracked and should be ignored. The second song's stems and the OGW media are referred to by path only.

Owner's decisions (2026-10-16): the index is "VerkCoding"; the start action is renamed "ReaperForVisual - Start or stop"; the user still chooses what is shown, helped by a first card; no Vietnamese README, and no Vietnamese left in any file; screenshots later; the clean install tested if it can be; the owner publishes to GitHub, and only an AI assistant's signatures are to be taken out (none were found: the repository has no commit yet, and no file carries such a line).

### Step 11 as built (2026-10-16)

- **The package**: `tools/make_index.py` writes `index.xml`: one package "ReaperForVisual" in category "ReaperForVisual" of the index "VerkCoding"; the seven actions (`main="main"`), the fifteen engine modules beside them, the page's six files as web interface files under `rfv/`. A release reads every file from the git tag and records its SHA-256; `--local` links a served checkout without hashes. ReaPack's package list names a package by its `desc`, so `desc` is "ReaperForVisual" and the sentence about it is the package's description.
- **The engine without a web interface**: a box says what to click, in five steps, with the note about other computers on the network, and offers to open Preferences (`40016`, its name checked first). When started by another script, the same text goes to the console.
- **The first page**: with nothing chosen, a card asks what the stage should show, "The whole mix" or "The tracks selected in REAPER"; the choice is kept as before (`.rfv.json`, or ExtState for an unsaved project). "not started" names the action to run.
- **The texts**: README for users (install in five steps, first use, reading the stage, sections, choosing, keys and toolbars, questions, limits, update and uninstall, licence); CONTRIBUTING for developers (DCO, layout, running from a checkout, tests, releasing, trying an index). Tests and comments in English (accented group names in French now).
- **The clean install, done for real** (a second REAPER 7.82 on a new resource folder, `-newinst -cfgfile`, audio closed when not playing, ReaPack 1.2.6, the index served from this computer, the owner's REAPER untouched): ReaPack's first start shows its default repositories (OK); *Import repositories...* added "VerkCoding" and fetched only that index; *Browse packages*, right-click, *Install v0.1.0*, OK, and a report ("Installed (1)", OK) put 22 files in `Scripts/VerkCoding/ReaperForVisual/` and 6 in `reaper_www_root/rfv/`, and registered the seven actions, which the Action List shows as "Script: ReaperForVisual - ... .lua". Started without a web interface: the box, then Preferences opened (on General). *Control/OSC/web* is near the end of a list that scrolls; *Add* offered port 8080; after OK, `csurf_0=HTTP 0 8080` was in `reaper.ini` and every page file was served. Started again: running, the first card, "The whole mix" chosen (the card closed, the "Show all or chosen" light on: its command was found under the ReaPack path); stopped: "engine stopped", the light off.
- **Found by the clean install, and fixed**: ReaPack listed the package by its long sentence (now "ReaperForVisual"); README now says to click OK on ReaPack's first list and on its report, to scroll the Preferences list, and names actions as the Action List shows them; the About panel's links (and the debug page's "Stage") were the browser's dark blue on the dark theme (now the page's accent colour).
- **Tried and dropped**: opening Preferences at Control/OSC/web. `ViewPrefs(0, name)` with "csurf", "control", "controlsurf", "csurfs", "osc" and "web" opened General; the names are not documented. The Preferences *Find* box finds "web" on the Keyboard page first.
- **The release path, tried on a copy**: the files git would publish (95; no media, no `.markdown-collab/`, no `index-local.xml`) committed and tagged `v0.1.0` in a scratch folder; the index's 28 hashes equal the SHA-256 of the tag's files and of the working files with LF endings (six of them are CRLF on Windows).

### Step 11 reviewed (2026-10-16)

- **Logical**: every README step was followed as written on a REAPER that had never seen the tool, except the GitHub link (the repository does not exist yet). Update and uninstall through ReaPack were not tried (they need a second version). The index's name keeps a ReaPack install apart from a development checkout's junction. `engine_test` passes after the changes; the owner's running engine went on.
- **Factual**: ReaPack's menus, dialogs and words, REAPER's Action List names and the web interface's default port are as seen in the test, not as remembered. The browser opening by itself could not be seen in the test (the user's browser is outside what the test may look at); it was seen in step 3.
- **User-oriented**: the steps that stop a beginner are ReaPack itself (once) and the web interface (once, with a box that says how); both are REAPER's own settings, so the user makes them. Four things were left to the owner, who chose every recommendation (2026-10-16): the repository is `VerkCoding/ReaperForVisual` (now `make_index.py`'s default); two sentences of this file that named the AI assistant as the one who acted are reworded; the start action is registered again on the owner's REAPER under its new name (the old entry removed; the toolbar button is the owner's to point at it); the tests take this computer's paths from REAPER's environment or from `tests/local_paths.lua`, which git ignores, and skip, or say what is missing, without them (tried both ways: `roles`, `snapshot`, `axes_second`, the band fixture), and this file no longer names the owner's folders (the projects' names stay).

## What is shown: only the tracks the user chose

The default view is **only the tracks the user chose**, not every track.

- To choose, the user selects tracks in REAPER and runs **"ReaperForVisual - Show selected tracks"**. This takes a snapshot, so later clicks on other tracks do not change the view. There are also "Add selected", "Remove selected", "Group selected" (a display-only group) and "Show all or chosen".
- The page's track checklist is the second way to choose.
- With nothing chosen, the page shows the speakers, the listener and a card that asks what to show: "The whole mix" or "The tracks selected in REAPER" (step 11).
- Choosing a bus shows it as one object, measured at the bus output. Choosing a bus and its children shows the group with its members inside.
- New tracks are not added automatically.
- Optional: the rest of the mix as one grey cloud (off by default).

## Storage: `<project>.rfv.json` beside the `.rpp`

- Holds the view set (`view.mode` "chosen" or "all"), display-only groups, role overrides and section settings, keyed by **track GUID** so renaming, reordering and cut-and-paste keep it. Format: [spec/rfv-json.md](spec/rfv-json.md).
- **One source of truth, no stale copies.** Every script (engine, each action) keeps only a cache. A change reads the latest copy, applies itself and writes at once, so two scripts, or a file synced by another program, never undo each other's changes.
- **Unsaved project**: choices live in non-persistent ExtState, one key per tab, visible to every script, and move into the file at the first save, whether or not the engine was running then.
- **Save As** is recognised by content, not by name: the same track GUIDs and the same item GUIDs. Track GUIDs alone are not enough, because songs made from one template share them. Choices are not copied into backups (`Backups` folders, `.mcp-backup-` files, non-`.rpp` files).
- **Safety**: atomic write through `.tmp` with the old file moved to `.old` and recovery from either; a damaged file is reported and kept under a free `.bad` name on the user's next change; a file from a newer version is read only; a failed write is reported and leaves the old file intact.
- **For the page (step 6)**: `st.error` codes (damaged, foreign, newer, write-failed) for a visible message; `S.missing` lists chosen tracks that no longer exist; `S.adoption_candidates` lists other `.rfv.json` files in the folder that fit this project (Save As made while the tool was off, a renamed `.rpp`), to be offered, never taken silently.
- Each project tab has its own file; the page follows the active tab.
- REAPER's "Clean current project directory" (40098) does not offer `.rfv.json` for deletion. Measured 2026-10-11 on REAPER 7.82: it scans only the project's media path (`RECORD_PATH`). With "Media" it never looks beside the `.rpp`. With the project folder itself it counted 5 files there (`.rpp`, `.rfv.json`, two WAVs, a `.reapeaks`) and listed only the unused WAV.

## The three axes

| Axis | Source | Measured accuracy | Limits |
|---|---|---|---|
| X | track meter L/R (after FX, fader and pan) → tangent law, over the last 0.5 s | live on the band fixture: 0.00° median per section, p90 0.7°, max 2.9° (own); heard 0.00°, p90 0.4° | a bus whose FX move or widen the image (a widener: 9.3°) is flagged, and its tracks' heard X is then off |
| Y | the track's files through its accessor (before its FX), mapped ahead of the play position in 0.5 s blocks → spectral centroid over the last 2 s, through the track's pan matrix; buses and groups from their tracks by the power each brings, returns from their sends (step 7) | live on the band fixture: 0.121 octave median per section (p90 0.64); without track FX 0.091, before their FX 0.219; buses 0.180, returns 0.296; calib exact | read before the track's FX (an EQ'd hi-hat or ride: 2–3 octaves; tagged "before FX"); a virtual instrument or a live input has no files: "?", with the share of a group's power that has no Y; a take FX parameter change is not seen |
| Z | meter power over the last 2 s minus a crest factor from the peaks' max/mean (raw peaks rebuilt from the meter's fixed decay), coefficients fitted on REAPER's own readings and following the meter's measured step and refresh | live: band 0.93 dB median per section (p90 2.3), heard 0.92 dB (p90 2.7); SessionHoangDa's stems, which the model never saw, 0.83 dB per 2 s window (p90 2.1), 0.80 per 20 s (p90 1.9) | pure tones read about 1.5 dB low (a sine's crest is 3 dB, music's more), white noise about 5 dB high (its peaks are as steady as dense music's); fitted on one song, checked on a second source |
| Width | left/right correlation of the same files, through the track's pan matrix (a width setting is counted) | band: 0.000 median and p90; calib exact, anti-phase −1 | before the track's FX, so a widener is not seen (tagged "before FX") |
| Groups | X and Z of a group measured at its bus output; members are carried up through each bus's volume stages, pan matrix and FX gain (their share of the bus), and silenced by mute and solo as REAPER does | nest: heard X 0.04°, Z change 0.02 dB; a bus's only input heard exactly as the bus's own meter (0.00 dB, 0.00°) through trim, pre-FX volume and pan, width, VCA, read mode and a pre-fader send; band: see X and Z | correlated members (room mics) are summed as powers; a send taken before the FX ignores them |
| Stopped | where the song played, each track's power as its meter measured it there, through its fader and pan as they are now; elsewhere its files at the edit cursor (the next 2 s) through its fader, pan and buses, times the FX gains learned while playing (step 9a and its review); an armed, monitored track keeps its meter | band, per section, after one play: Z 0.94 dB median (the meters' own accuracy), X 0.00°; against the meters over the same 2 s, 0.90 dB; never played: Z 2.04 dB (tracks with FX 3.56) | an FX parameter moved since the part last played is not seen; FX never heard are not in the level (marked); a virtual instrument never heard has no level; where nothing played, drum hits read from short windows are 2 dB off and more |

### Images outside the speakers

Decision: version 1 marks anti-phase content but does not place it at an angle.

- When a track's L/R correlation from the accessor falls below zero, its width extends past the speakers and it gets a phase marker. The tooltip says the measurement is before track FX.
- No extra cost: the correlation is already computed for the width.
- Not covered in version 1: virtual instruments (no accessor data), wideners after the track's own FX, and cancellation between different tracks (for example kick in against kick out). Those need a render.

## Sections

The user marks the sections; the page shows each section's average stage beside the realtime view. Agreed 2026-10-10:

1. **Regions** are sections by default, one section per region, named after the region.
2. A project without regions can use **markers whose name starts with `#`** (for example `#Chorus 2`). Each runs to the next `#` marker or the project end. Other markers are ignored, so notes such as "Check Gain Vox" do not split the song.
3. A page setting switches between regions, `#` markers, all markers, or no sections. The setting is stored in `.rfv.json`.

Sections that have been played use measured values; sections not yet played use the model and say so.

## Fonts

No downloaded fonts, so nothing needs installing. Arial is the closest thing to a font on all three systems: it ships with Windows and macOS, and Linux distributions map it to the metric-compatible Liberation Sans or Arimo.

```css
font-family: Arial, "Liberation Sans", Arimo, Helvetica, sans-serif;
font-variant-numeric: tabular-nums;   /* aligned readouts */
```

three.js is bundled with the page, so it works without internet.

## What the user has to do

| When | Action |
|---|---|
| Once per machine | Install the package through ReaPack (it registers every action and puts the page under `reaper_www_root/rfv/`); turn on REAPER's web interface if it is off (the engine says how, and offers to open Preferences). |
| Once per project | Choose what is shown: the page's first card (the whole mix, or the tracks selected in REAPER), the actions "ReaperForVisual - Show selected tracks" (or Add, Remove, Group), or the page's checklist; correct a role or a main path on the page if the routing guessed wrong. |
| Each session | Run "ReaperForVisual - Start or stop" (or let it start with REAPER). |

Importing stems and mixing need nothing extra; groups appear when the user makes folders or sums with sends.

## Distribution

GitHub first, with our own ReaPack index in the same repository (users add the repository URL in ReaPack).

Licence goals (owner, 2026-10-10; Commons Clause rejected for its weaknesses and the FOSS community's objections):

1. Audio engineers may use the tool to make music, mix and master, and earn money from their audio.
2. Lazy individuals and large companies must not be able to copy or repackage the code and sell it without real work.
3. Developers who build a genuinely new product of quality on this technology must not be blocked.

**Decided 2026-10-10** (the owner asked for "enough, nothing missing, nothing extra that bothers people who build something new"):

| Part | Licence or rule | Goal |
|---|---|---|
| Engine and page | **AGPL-3.0-only**, unmodified, with no additional terms. Anyone who distributes the tool, a changed version, or runs it as a network service must publish the full source under the same licence. It never reaches what the program helps produce: audio, mixes, renders and screenshots belong to the user. "-only" so a future licence version does not apply without the owner's choice. | 1, 2 |
| Name and logo | One short README paragraph: not licensed under the AGPL; forks use another name. No registration for now. | 2 |
| Other terms | One README line: "For other licensing terms, contact the author." The sole author can grant a proprietary licence for a genuinely new product, case by case. | 3 |
| `.rfv.json` format specification and schema | **MIT** in its own folder, so other tools can read and write view sets. | 3 |
| Bundled three.js | keeps its own MIT licence (compatible with the AGPL) | |
| Contributions | Developer Certificate of Origin (a `Signed-off-by` line), no CLA. If outside code becomes substantial and commercial licences are wanted, add a CLA then. | |

Already required by AGPLv3 itself, so nothing extra is written: changed versions must carry a notice that they were changed, with a date (section 5a), and the interface must show the copyright and licence notices (section 5d). The page gets an About panel with the copyright, the licence and a link to the source, which also covers section 13 for network use.

Dropped as excess: additional section 7 terms (they duplicate 5a and 5d and complicate combining with other GPL code), a separate trademark policy file, and a CLA while there is a single author.

Every source file starts with `SPDX-License-Identifier: AGPL-3.0-only` and the copyright line. The full licence texts are copied verbatim from gnu.org and opensource.org when the repository is scaffolded.

What no licence can do:

- Stop a copy from being sold. Selling copies is a freedom under the GPL family. Copyleft makes it a poor business, because every buyer receives the source and the right to share it for free, and the trademark layer stops a reseller using our name.
- Protect algorithms or ideas, such as the tangent law or the routing roles. Copyright covers the code as written. Anyone may reimplement the ideas from scratch, which is also how genuinely new products get made.
- Judge "changed too little". Copyleft avoids that test by applying the same terms to every derivative.

Not legal advice: the trademark registration and the CLA wording are worth a lawyer's look.

## Reference definitions (ground truth, step 2)

The engine is judged against these; `tools/truth_stats.py` implements them.

- **Level**, three kinds, because the choice for Z waits for step 5's numbers:
  - `level_db`: 10·log10(PL + PR) over the whole section, with PL and PR the mean power of left and right. Silence is included.
  - `level_active_db`: the same over 400 ms blocks (hop 100 ms) that pass a gate, absolute −70 dB and then 10 dB under their mean. This is the level while the part plays. A shaker heard only now and then in the band fixture reads −48.1 dB over a section but −36.1 dB while playing.
  - `loudness_lufs`: ITU-R BS.1770 integrated loudness of the section (K-weighted, same gates).
- **Azimuth**: tangent law with speakers at ±30°, from the RMS amplitudes √PL and √PR. `az_p10` and `az_p90` are the 10th and 90th percentiles over the active blocks: how far a moving part travels.
- **Centroid**: 2^(Σ P(f)·log2 f / Σ P(f)) over 20 Hz–20 kHz, where P is the Welch power spectrum (2,048-point Hann) of left plus right. `centroid_a_hz` is the same with P A-weighted, to compare in step 7.
- **Sections**: every region, plus "all" for the whole project.
- **Ground truth**, rendered in a temporary tab with REAPER's own FX only, in two layers:
  - **own**: each track's output as a 32-bit stem, after its FX, fader and pan. A folder's stem is exactly the sum of its children, measured to −149 dB.
  - **heard**: each track "via master", through its parent buses and the master, on fixtures without sends (solo also passes sends).
- **Checked against arithmetic**: `calib` (28 values) and `nest` (20 values: buses in balance, stereo-with-width, dual pan, −3 and −6 dB laws, two levels deep) all pass. Building and rendering `band` twice gave identical numbers.
- **Not covered by arithmetic**: a widener on a bus (its truth is the render). Near-silent leakage passes the −70 dB gate (the shaker reads −60 dB "while playing" in a section where it is silent), so the page also needs a threshold relative to the loudest part (step 8).

## REAPER's pan, as measured (2026-10-11)

A 2×2 gain matrix, from a tone fed into the left channel only and into the right only, across 24 settings. Every setting matched within 0.002 in gain (0.02 dB). The engine needs this to place a child where it is heard (step 5).

| Mode | Matrix (outputs L, R from inputs L, R) |
|---|---|
| Balance, 0 dB law | far side × (1 − \|p\|), near side × 1; nothing crosses |
| Balance, −3 dB law | sine/cosine, constant power: L = cos θ, R = sin θ with θ = (p + 1)·45°, scaled so the centre is −3.0 dB |
| Balance, −6 dB law | linear: L = (1 − p)/2, R = (1 + p)/2, scaled so the centre is −6.0 dB |
| Stereo (mode 5) | width first: (1 + w)/2 to its own side and (1 − w)/2 across. Then a **stereo pan**: at +p, left goes (1 − p) to L and p/2 to R; right goes (1 − p/2) to R. Mirrored at −p |
| Dual (mode 6) | each channel by the 0 dB law on its own pan; a channel at 0 plays at full level on both sides |

The plugin's reaper-panning skill said stereo mode was "width, then balance". That only holds when the channels are nearly the same. It was corrected the same day. Pan envelopes store pan inverted (envelope −1 = pan right), confirmed by render.

## Measured facts (REAPER 7.82, temp tabs, 2026-10-10)

- Web interface: `/_/TRACK` has one combined meter per track (index 0 is the master). `GET/EXTSTATE` at 10 Hz: median 16 ms, p99 42 ms. The first request to `localhost` takes 2 s (IPv6 fallback); relative URLs avoid it. Values sent with `SET/EXTSTATE` are cut at about 1,000 URL-encoded bytes. Files in `%APPDATA%\REAPER\reaper_www_root` are served at once, without a restart, and the built-in pages keep working.
- `Track_GetPeakInfo(track, 0|1)`: left/right after FX, fader and pan; exact; works for virtual instruments and buses; the value carries the meter's decay; 224 tracks read in 0.057 ms per cycle. *Corrected 2026-10-11:* the meter refreshes about every 46 ms and falls 1.4 dB per refresh, 30 dB/s, which is the `vudecay` setting (30). The earlier "46 dB/s" came from reading every 31 ms and taking each 1.4 dB step as one tick.
- Track AudioAccessor: before track FX, fader and pan, after item volume, take pan, take FX and playrate; silent for MIDI with a virtual instrument; reads media that `offlineinact` has taken offline; about 1 ms per track per 2,048-frame window, FFT included.
- Peak versus RMS: 3.7–13.5 dB on raw sources (11.1 dB median with meter decay). Crest predicted from the meter's cycle-to-cycle jumps: median 1.6 dB off, p90 4.3 (leave one track out, 200 sections).
- Role classifier prototype: 48/48 right on a 48-track mix in 0.6 ms; 23/24 on a test project mixing routing styles; 2.4 ms for 224 tracks.
- Track GUID (2026-10-11): unchanged by rename, reorder, save and reload, delete followed by undo, and cut followed by paste; a duplicate or a copy-and-paste gets a new GUID. **A project opened as a template keeps the template's track GUIDs**, so two songs made from one template share GUIDs: shared GUIDs alone do not prove two files are the same project. The master track has its own GUID, kept across save and reload. "Save new version of project" (41895, `Bài hát.rpp` → `Bài hát_001.rpp`) is a Save As the store follows. REAPER's Lua `io.open`, `os.rename`, `os.remove` and `RecursiveCreateDirectory`, and `Main_SaveProjectEx`/`Main_openProject`, all handle Vietnamese characters in paths.
- Read-only proof: a prototype engine running while stopped and while playing left the project state counter, dirty flag, undo and redo unchanged. Selecting tracks, by API or by action, changed neither the dirty flag nor undo.

## Next

1. Third test (~30–45 min): track GUIDs across save, reload, undo and reorder; `.rfv.json` on Save As, on an unsaved project and with a Vietnamese path; an action passing a view set to the running engine.
2. A build plan with P/P/S per step, for approval. Current estimate 12.5–14.5 hours.
3. Checks against renders, aiming at X ≤ 1°, Y ≤ 0.25 octave and Z ≤ 1 dB (median per section). Use other projects too, so the crest model is not fitted to one song.
