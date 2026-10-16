<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 VerkCoding -->

# `.rfv.json`, version 0

What a ReaperForVisual user chose for one REAPER project: which tracks to show, display-only groups, role overrides and where sections come from. Any tool may read and write it (MIT licence, see [LICENSE](LICENSE)).

## Where it lives

Beside the project file, with the same base name: `D:\Songs\Mix.rpp` → `D:\Songs\Mix.rfv.json`. The `.rpp` extension is matched without regard to case.

A project that was never saved has no file. ReaperForVisual keeps its choices in REAPER's non-persistent ExtState (section `ReaperForVisual`, key `unsaved <project pointer>`) so every script sees them, and moves them into the file at the first save.

## Encoding

- JSON as in RFC 8259, UTF-8. Readers skip a UTF-8 byte order mark; writers do not write one.
- Writers should indent with two spaces and sort object keys, so a file that did not change in meaning does not change in bytes. Readers must not depend on either.

## Top level

```json
{
  "format": "rfv",
  "version": 0,
  "view": { "mode": "chosen", "tracks": ["{271E9615-8FE7-4419-B7C5-7D27F5A3B2B7}"] },
  "groups": [{ "name": "Drums", "tracks": ["{...}", "{...}"] }],
  "roles": { "{...}": "return" },
  "paths": { "{...}": "{...}" },
  "sections": { "source": "regions" },
  "labels": { "{271E9615-8FE7-4419-B7C5-7D27F5A3B2B7}": "Lead vox" },
  "items": ["{...}", "{...}"],
  "project": "Mix.rpp"
}
```

| Key | Type | Meaning |
|---|---|---|
| `format` | string, required | always `"rfv"` |
| `version` | integer, required | `0` for this document |
| `view.mode` | string | `"chosen"` (default): show the tracks in `view.tracks`, nothing else, and new tracks stay hidden. `"all"`: show the whole mix at the default level: one object per group just under the mix bus, and every return (reverb, delay, parallel bus) as an object of its own wherever it sits; `view.tracks` and `groups` are kept for when the mode goes back to `"chosen"`. |
| `view.tracks` | array of GUID | the chosen tracks. Order is not significant. |
| `groups` | array of objects | display-only groups: `name` (string) and `tracks` (array of GUID). They exist only in the viewer, never in the project. A track belongs to at most one group; a reader that finds one in several keeps the first. |
| `roles` | object, GUID → string | overrides of the role read from routing: `"source"`, `"bus"`, `"return"`, `"ignore"`, or `"layer:<GUID>"` for a parallel layer of the group or bus with that GUID. An override decides how the track is drawn; the routing's own answer is still shown beside it. |
| `paths` | object, GUID → GUID | optional: for a track whose master/parent send is off and whose loudest sends are at the same level, the destination that is its main path. Without it the destination first in track order is taken, and the track is flagged. |
| `sections.source` | string | where sections come from: `"regions"` (default: each region is a section, except a region over 90 % of the song or more, which is taken for a render region; a project with no other region uses the `#` markers), `"markers#"` (each marker whose name starts with `#` starts a section that runs to the next one or the song's end; other markers are notes), `"markers"` (every marker starts a section, to the next one or the song's end; a marker at the song's end and a section under 2 s are left out) or `"off"` |
| `labels` | object, GUID → string | informational: each named track's name when the file was written, for people reading the file. Never used to find a track. |
| `items` | array of GUID | informational: up to 32 item GUIDs spread over the project when the file was written, used to recognise the same project after a rename. |
| `project` | string or null | informational: the project's file name when the file was written |

### GUIDs

A **GUID** is written as REAPER's `GetTrackGUID` returns it: braces, upper-case hexadecimal, 8-4-4-4-12 digits. Readers compare GUIDs without regard to case. The master track may be named by its own GUID.

What a GUID survives (measured on REAPER 7.82): renaming, reordering, saving and reloading, delete followed by undo, cut followed by paste. A duplicated or copied-and-pasted track gets a new GUID. **A project opened as a template keeps the template's track GUIDs**, so two songs made from one template share them: matching track GUIDs alone do not show that two files are the same project. Item GUIDs differ between such songs, which is why `items` exists.

A GUID that names no track of the project (the track was deleted) stays in the file, because an undo can bring the track back. Readers ignore it when drawing.

## Rules for writers

- **Read, change, write at once.** Read the latest file, apply the change, write it back. Never write a copy held in memory from earlier, or another program's change is lost.
- **Keep what you do not know.** A key a reader does not understand is written back unchanged. Only a change that older readers would misread raises `version`.
- **A newer version is read only.** A file whose `version` is higher than the reader knows is never written; the user is told to update.
- **Write safely.** Write `<name>.tmp`, move the old file to `<name>.old`, rename the `.tmp` into place, then delete the `.old`. A reader that finds no file but a readable `.tmp` or `.old` uses it and puts it back under its name.
- **Never overwrite an unreadable file.** Report it. When the user next changes something, keep the old file as `<name>.bad`, or `<name>.bad-<date>-<time>` if that name is taken, then write a new one.
- **Follow the project, carefully.** After a Save As (same tracks and the same items under a new name), copy the document to the new name and leave the old file alone. Do not copy into a backup: a path inside a `Backups` folder, a name containing `.mcp-backup-`, or a file that does not end in `.rpp`. A user's own change there is still written.
- **Offer, do not guess.** When a project has no file but another `.rfv.json` in its folder names its tracks and items, offer it to the user; never take it silently.
