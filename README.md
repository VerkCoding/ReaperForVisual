# ReaperForVisual

See where every part of your REAPER mix sits: left or right, low or high, near or far. A 3D stage in your web browser follows the song while it plays, and shows any place in the song when it is stopped.

- **Read-only.** It never changes your project: not its tracks, its effects, its routing or its undo history.
- **On your computer only.** A Lua script runs inside REAPER, and REAPER shows the page in your browser. No internet, no account, no AI.
- **Free and open source**, under the AGPL-3.0.

ReaperForVisual is not made by Cockos. REAPER is a trademark of Cockos Incorporated.

## What you need

- REAPER 7 on Windows. It was tested with REAPER 7.82. macOS and Linux have not been tested yet.
- ReaPack, REAPER's free package manager. Step 1 below installs it if you do not have it.
- A web browser.

## Install (once, about five minutes)

1. **ReaPack.** If REAPER's menu bar already has *Extensions > ReaPack*, skip this step. Otherwise download ReaPack from [reapack.com](https://reapack.com/). In REAPER, choose *Options > Show REAPER resource path in explorer/finder*, put the downloaded file in the `UserPlugins` folder there, and restart REAPER. The first time, ReaPack shows its list of repositories: click *OK*.
2. **Add ReaperForVisual to ReaPack.** Choose *Extensions > ReaPack > Import repositories...*, paste this link and click *OK*:

   ```
   https://raw.githubusercontent.com/VerkCoding/ReaperForVisual/main/index.xml
   ```

3. **Install it.** Choose *Extensions > ReaPack > Browse packages...*, type `ReaperForVisual` in the *Filter* box, right-click *ReaperForVisual* and choose *Install*, then click *OK*. ReaPack lists what it installed: click *OK* again.
4. **Turn on REAPER's web interface.** This is what lets REAPER show the page in your browser. Choose *Options > Preferences*, scroll the list on the left down to *Control/OSC/web* (near its end), and click *Add*. Set *Control surface mode* to *Web browser interface*, keep the port it offers, leave the other settings as they are, and click *OK* twice. If you forget this step, ReaperForVisual tells you what to do when you start it, and opens Preferences for you.
5. **Start it.** Choose *Actions > Show action list...*, type `ReaperForVisual` in the *Filter* box, select *Script: ReaperForVisual - Start or stop.lua* and click *Run*. Your browser opens the stage. To stop it, run the same action again.

In the Action List, every ReaperForVisual action is named *Script: ReaperForVisual - ... .lua*. This page leaves out *Script:* and *.lua*.

To start it with one click, put *ReaperForVisual - Start or stop* on a toolbar (see [Keys, menus and toolbars](#keys-menus-and-toolbars)). The button lights while ReaperForVisual runs.

## First use

1. The page asks what the stage should show: **The whole mix**, or **The tracks selected in REAPER**. Your answer is kept for this project, and you can change it at any time.
2. Press play in REAPER. Each part moves to where you hear it.
3. Stop. The stage now shows the place where the edit cursor is. Click anywhere in the song to see that place.

Play the whole song once. From then on, the stage when stopped is built from what was measured while it played, so it is as accurate as it is while playing.

To look around: drag to turn the view, scroll to zoom, or use the *3D*, *Top* and *Front* buttons. Hover over a part to read its numbers and the meaning of its marks; click it to keep them shown.

## Reading the stage

| What you see | What it means |
|---|---|
| Left or right | Where you hear the part, after every pan, send and bus on its way to the master. The two blue posts are your speakers, and you sit at *YOU*. |
| Low or high | The part's spectral centre: deep parts sit near the floor, bright parts high up. The post at the back right shows the scale, from 40 Hz at the floor to 12 kHz at the top. |
| Near and big, or far and small | How loud the part is compared with the whole mix. The rings on the floor mark 0, -10, -20 and -30 dB. |
| Wide or narrow | How different the part's left and right are. A mono part is narrow; the less its two sides have in common, the wider it is. |
| A sphere | A track, a bus (measured at its output), or a group you made for display. |
| A cloud | A return, such as a reverb or a delay. |
| A faint shell | A bus or group shown with its tracks inside it. |
| Hollow | Muted, or silenced by a solo on another track. It stays where it was last heard. |

Parts more than 40 dB under the loudest part are hidden, so noise, bleed and dither do not clutter the stage. Change this with *Hide under* at the top of the page.

A line at the bottom of the page says what the stage is built from at this moment: measured while playing, or worked out from the files where the song has not been played yet.

### Marks next to a name

| Mark | Meaning |
|---|---|
| **?** | The sound does not come from audio files (a virtual instrument or a live input), so the part has no height of its own. *40 % ?* means 40 % of a group's level has no height. |
| **≈** | A return. Its height comes from what its sends bring it, before its reverb or delay. |
| **anti-phase** | Its left and right are out of phase: it is heard wider than the speakers, and it cancels in mono. |
| **est.** | A live input (an armed track with monitoring on), estimated through its own pan and fader, without its effects. |
| **approx.** | Its way to the master goes through a send taken before the effects, so those effects are not counted. |
| **image gap** | Effects on its bus move or widen the image, so the positions of the tracks in that bus are less exact. |
| **muted**, **silenced** | Muted, or cut by a mute above it or a solo elsewhere. Drawn where it was last heard. |
| **measured**, **model**, **FX?** | Only when stopped, where this part differs from the rest of the stage. *measured*: as its meter measured it here. *model*: from its files, with its effects as measured elsewhere in the song. *FX?*: its effects have not been heard yet, so play this part once. |
| **reading** | Its audio files are still being read, and its height may still move. This passes within the first minutes. |

## Sections

The first list at the top of the page shows a section of the song instead of the edit cursor: the section's average stage, and how much of it was measured while it played.

- Sections are your regions, one section per region, named after it. A region that covers almost the whole song (one made for rendering) is left out.
- A project without regions uses markers whose name starts with `#`, for example `#Chorus 2`. Each runs to the next `#` marker or the end of the project. Other markers, such as notes to yourself, do not split the song.
- The second list chooses where sections come from: regions, `#` markers, every marker, or none. The choice is kept for the project.

## Choosing what is shown

You choose which tracks the stage shows. *The whole mix* shows every track. With your chosen tracks, a new track appears only when you add it.

- **The first card**, in a project you have not set up yet: *The whole mix*, or *The tracks selected in REAPER*.
- **All / chosen**, at the top of the page: switch between the whole mix and the tracks you chose. *Undo* and *Redo* beside it step back and forward through your view changes while ReaperForVisual runs.
- **Tracks**, at the top of the page: a list of every track. Tick *Show* to put a track on the stage. If a track is drawn as the wrong kind, for example a reverb return drawn as an instrument, change its *Role* there. If a track reaches the master in more than one way, *Main path* chooses the one it is placed by.
- **REAPER actions** (in the Action List, type `ReaperForVisual`):

| Action | What it does |
|---|---|
| ReaperForVisual - Show selected tracks | Shows exactly the tracks selected in REAPER. |
| ReaperForVisual - Add selected tracks | Adds the selected tracks to the ones shown. |
| ReaperForVisual - Remove selected tracks | Takes the selected tracks out. |
| ReaperForVisual - Group selected tracks | Shows the selected tracks as one group, for display only. Your project gets no new folder. |
| ReaperForVisual - Show all or chosen tracks | Switches between the whole mix and your chosen tracks. Its toolbar button lights while the whole mix is shown. |
| ReaperForVisual - View menu | All of the above in one menu at the mouse, with Undo and Redo of view changes. |

None of them changes your project.

### Keys, menus and toolbars

- **A key:** in the Action List, select the action, click *Add...* under *Shortcuts for selected action*, press the key, then click *OK*. *ReaperForVisual - View menu* is a good one to give a key: it holds all the others.
- **A toolbar button:** choose *Options > Customize menus/toolbars...*, pick a toolbar in the list at the top, right-click where the button should go, choose *Insert action...*, find the action, click *Select/close*, then save.
- **The track's right-click menu:** the same window, with *Track control panel context* chosen at the top.

## What it keeps, and where

- **Your choices** (what is shown, display groups, corrected roles and main paths, where sections come from) go to a small file next to your project, `<project>.rfv.json`, when you change them. In a project that has never been saved, they wait until you save it. If that file is ever damaged, it is kept aside under a name ending in `.bad`, never deleted.
- **What playing measured** goes to REAPER's resource folder, `Data/ReaperForVisual/learned`, one file per project. That is how the stage when stopped stays accurate in your next session.
- Nothing else is written. The `.rpp` file is never touched.

The `.rfv.json` format is open (see [spec/](spec/)), so other tools can read and write it.

## How accurate it is

Each number was measured against renders of every part on its own, on real songs.

- **Left or right:** within 1 degree nine times out of ten, for each part in each section of the song.
- **Level:** within about 1 dB per section of the song (the median) on the song it was tuned on, and about 1.5 dB on a second song. A drum trigger, short clicks with silence between them, can show up to 15 dB too loud.
- **Height:** within about a tenth of an octave (the median) for parts without effects. It is read before the track's effects, so a part with a strong EQ can be two or three octaves off.
- **Stopped:** where the song has played, as accurate as while playing. Where it has not, about 2 dB, and more for tracks with effects.

## Known limits

- Height and width come from each track's audio files, before its effects. An EQ or a stereo widener on a track does not move it, and a return's height comes from what its sends bring it.
- A virtual instrument or a live input has no height of its own (*?*).
- While recording, an armed track with monitoring on is estimated from its input, without its effects (*est.*).
- A drum trigger can show too loud (see above).
- A setting changed inside an effect, or an item moved, shows once that part plays again.
- On a large project still being read, a few short parts may show no height for a while.
- Tested on Windows only. Touch screens have not been tried.

## Questions

**What does the word at the top left mean?**

| It says | What to do |
|---|---|
| connecting to REAPER... | Wait a moment: the page is reaching REAPER. |
| running | Nothing: ReaperForVisual is running. |
| not started | Run *ReaperForVisual - Start or stop* in REAPER. |
| engine stopped | It was stopped. Run *ReaperForVisual - Start or stop* to start it again. |
| paused (REAPER busy?) | REAPER is not running scripts at the moment. Close any dialog box in REAPER that waits for an answer: while one is open, scripts wait. |
| REAPER's web interface is not answering | REAPER is closed, or its web interface is off or on another port. See step 4 of the install. |

**The browser did not open.** Open `http://127.0.0.1:8080/rfv/index.html` yourself, with the port of your web interface instead of 8080 if it is different. REAPER shows the port in *Options > Preferences > Control/OSC/web*.

**The stage is empty.** Check that tracks are chosen (the *All / chosen* button, or the *Tracks* list), that the parts are not under the *Hide under* limit, and that something sounds at the edit cursor.

**Nothing moves.** Press play. While stopped, the stage stands still at the edit cursor.

**I have several projects open.** The page follows the project tab that is active in REAPER.

**I saved my project under a new name.** If ReaperForVisual was running, your choices follow the project. If it was not, the *Tracks* list offers the choices it finds next to the project: click *Use them*.

**Does it change my project?** No. It only reads. See [What it keeps, and where](#what-it-keeps-and-where).

**Does it use the internet?** No. REAPER serves the page to your own browser. REAPER's web interface can also be opened from other computers on your network. To limit that, fill in *Username:password* where you added the web interface.

**Is it heavy?** No. On a 48-track project it uses about half a millisecond of REAPER's time, ten times a second. On 224 tracks, about 2 milliseconds.

## Update and uninstall

- **Update:** *Extensions > ReaPack > Synchronize packages*.
- **Uninstall:** *Extensions > ReaPack > Browse packages...*, right-click *ReaperForVisual*, choose *Uninstall*, then click *OK*. If you like, also delete the `Data/ReaperForVisual` folder in REAPER's resource folder and the `.rfv.json` files next to your projects.

## Help and feedback

Found a problem, or have an idea? Open an issue on [GitHub](https://github.com/VerkCoding/ReaperForVisual/issues). For a problem, say which REAPER version you use, what you did, and what the word at the top left of the page said.

## Licence

- ReaperForVisual is licensed under the [GNU Affero General Public License v3.0 only](LICENSE). Use it for any audio work, paid or not: the music, mixes and renders you make with it are yours.
- The `.rfv.json` format in [spec/](spec/) is under the [MIT licence](spec/LICENSE), so other tools can use it.
- The name "ReaperForVisual" and its logo are not licensed under the AGPL. A modified version must use another name.
- Includes [three.js](https://threejs.org/) (MIT licence).
- For other licensing terms, contact the author.

Copyright (C) 2026 VerkCoding.

Want to help, or build it yourself? See [CONTRIBUTING.md](CONTRIBUTING.md).
