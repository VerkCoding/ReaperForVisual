-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Expected roles, written by hand from each project's routing (tools/rpp_survey.py --tracks
-- and the send levels) before the classifier was run on it. Tracks are 1-based in track
-- order. A track not listed under a role is a source; a track not listed under flags has none.
-- groups/levels/kinds are spot checks.

local E = {}

local function range(a, b, t) t = t or {}; for i = a, b do t[#t + 1] = i end return t end
local function cat(...) local t = {}; for _, x in ipairs({ ... }) do for _, v in ipairs(x) do t[#t + 1] = v end end return t end

-- The styles fixture is named by track name (tests/fixtures/styles.lua).
E.styles = {
  mixbuses = {},
  roles = {
    bus = { "Drums", "Type BV", "Vox bus", "Gtr bus", "Perc (folder with items)", "Inner" },
    passthrough = { "Group BV", "Outer" },
    ["return"] = { "Verb", "Gtr par" },
    ignored = { "Ghost SC to parent 3/4", "VOCALS (organizing)", "Keys MIDI", "Click to phones", "Empty",
                "Pad offline", "Pad bypassed", "Synth chain off", "Tone JS", "MIDI only", "STRINGS (send off)" },
  },
  kinds = {
    ["Ghost SC to parent 3/4"] = "unheard", ["VOCALS (organizing)"] = "organizing", ["Keys MIDI"] = "midi_to_instrument",
    ["Click to phones"] = "unheard", Empty = "empty", ["Pad offline"] = "midi_no_instrument", ["Tone JS"] = "midi_no_instrument",
    ["Keys synth 4ch"] = "instrument", ["Keys out 3/4"] = "output", ["Live mic"] = "live", Takes = "items",
    Verb = "sends", ["Gtr par"] = "parallel", Drums = "folder", ["Vox bus"] = "sends",
    ["STRINGS (send off)"] = "organizing", Choir = "items",
  },
  flags = {
    ["Room (muted)"] = { "muted" }, ["Ghost SC to parent 3/4"] = { "side_parent" }, Verb = { "parallel" },
    ["Gtr L"] = { "tie" }, ["Gtr R"] = { "tie" }, ["Gtr par"] = { "parallel" }, ["Live mic"] = { "live" },
    ["Perc (folder with items)"] = { "own_sound" }, ["Click to phones"] = { "hw_only" },
    ["Pad offline"] = { "midi_no_instr" }, ["Pad bypassed"] = { "midi_no_instr" }, ["Synth chain off"] = { "midi_no_instr" },
    ["Tone JS"] = { "midi_no_instr" }, ["MIDI only"] = { "midi_no_instr" },
  },
  groups = {
    Kick = "Drums", ["Room (muted)"] = "Drums", Drums = "Drums", ["Bass 4ch"] = "Bass 4ch", Lead = "Vox bus", Harmony = "Vox bus",
    ["Type BV"] = "Vox bus", ["Group BV"] = "Vox bus", Verb = "Verb", ["Gtr L"] = "Gtr bus", ["Gtr par"] = "Gtr par",
    ["Keys out 3/4"] = "Keys out 3/4", Shaker = "Perc (folder with items)", Deep = "Outer", Inner = "Outer", Empty = 0,
    Choir = "Vox bus", ["STRINGS (send off)"] = 0,
  },
  levels = { Kick = 1, Harmony = 2, Deep = 1, Drums = 0, ["Bass 4ch"] = 0 },
}

E.ogw = {
  file = "ForMixingV2/OurGoodWolf_Tourism_TryingNewSettings.rpp", n = 48,
  mixbuses = { 1 },
  roles = {
    mixbus = { 1 },
    bus = { 2, 3, 6, 10, 14, 20, 23, 27, 31, 33, 34, 37, 43 },
    passthrough = { 19, 22, 26, 30 },
    ["return"] = range(44, 48),
    ignored = {},
  },
  flags = { [44] = { "parallel" }, [45] = { "parallel" }, [46] = { "parallel" }, [47] = { "parallel" }, [48] = { "parallel" } },
  groups = { [4] = 2, [21] = 19, [24] = 22, [32] = 30, [35] = 33, [44] = 43, [2] = 2, [19] = 19, [1] = 0 },
  levels = { [4] = 2, [21] = 1, [44] = 1 },
}

E.hoangda = {
  file = "SessionHoangDa/SessionHoangDa.rpp", n = 57,
  mixbuses = { 1 },
  roles = {
    mixbus = { 1 },
    bus = { 2, 8, 9, 13, 17, 19, 22, 33, 41, 44, 46, 49 },
    passthrough = { 3, 4, 5, 10, 11, 14 },
    ["return"] = { 6, 7, 12, 15 },
    ignored = cat({ 16, 32, 48 }, { 20, 21 }, range(23, 31), range(35, 40), { 42, 43, 45, 47 }, range(50, 55), { 57 }),
  },
  kinds = { [16] = "organizing", [32] = "organizing", [48] = "organizing", [20] = "empty", [18] = "items", [17] = "sends" },
  flags = { [6] = { "parallel" }, [7] = { "parallel" }, [12] = { "parallel" }, [15] = { "parallel" } },
  groups = { [18] = 2, [34] = 8, [56] = 13, [6] = 2, [12] = 8, [15] = 13, [9] = 8, [3] = 2, [1] = 0, [20] = 0 },
  levels = { [18] = 2, [34] = 3, [56] = 2 }, -- 34: [TYPE] Elec Gtr, [BUS] Guitars (two inputs), [GROUP] Instruments
}

E.tiki = {
  file = "SessionHoangDa/Tiki Horea mix template.rpp", n = 135,
  mixbuses = { 1, 2 },
  roles = {
    mixbus = { 1, 2 },
    bus = { 4, 5, 6, 8, 9, 13, 18, 23, 30, 33, 36, 41, 44, 51, 59, 65, 68, 71, 75, 78, 79, 86, 92, 93, 96, 99, 102, 106, 120, 128 },
    passthrough = {},
    ["return"] = cat(range(107, 119), range(121, 127)),
    ignored = cat({ 3, 7, 105 }, range(10, 12), range(14, 17), range(19, 22), range(24, 29), { 31, 32, 34, 35 }, range(37, 40),
                  { 42, 43 }, range(45, 50), range(52, 58), range(60, 64), { 66, 67, 69, 70 }, range(72, 74), { 76, 77 },
                  range(80, 85), range(87, 91), { 94, 95, 97, 98, 100, 101, 103, 104 }, range(129, 135)),
  },
  kinds = { [105] = "organizing", [3] = "empty", [10] = "empty", [122] = "parallel", [107] = "sends" },
  flags = (function()
    local f = { [2] = { "parallel" } }
    for _, k in ipairs({ 4, 5, 6, 13, 18, 23 }) do f[k] = { "tie" } end
    for _, k in ipairs(cat(range(107, 119), range(121, 127))) do f[k] = { "parallel" } end
    return f
  end)(),
  groups = { [8] = 5, [13] = 5, [79] = 6, [122] = 5, [41] = 41, [44] = 4, [2] = 0, [5] = 5, [107] = 6, [129] = 0 },
  levels = { [13] = 2, [79] = 2 },
}

E.forrecord = {
  file = "SessionHoangDa/ForRecord.rpp", n = 23,
  mixbuses = { 1 },
  roles = {
    mixbus = { 1 },
    bus = { 2, 11, 14, 19 },
    passthrough = {},
    ["return"] = { 20, 21, 22 },
    ignored = { 3, 4, 8, 9, 10, 23 },
  },
  kinds = { [5] = "live", [18] = "live", [23] = "empty", [3] = "empty" },
  flags = (function()
    local f = { [20] = { "parallel" }, [21] = { "parallel" }, [22] = { "parallel" } }
    for _, k in ipairs({ 5, 6, 7, 12, 13, 15, 16, 17, 18 }) do f[k] = { "live" } end
    return f
  end)(),
  groups = { [5] = 2, [12] = 11, [18] = 14, [20] = 19, [2] = 2, [19] = 19, [1] = 0 },
}

return E
