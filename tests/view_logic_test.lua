-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 6, method only: engine/rfv_view.lua. The changes the actions and the page make to a
-- .rfv.json document, the names given to new groups, and the stage the choices resolve to (on a
-- small routing written by hand: Drums > Kick > Kick in / Kick out, Drums > Snare, Bass, a
-- reverb return, all under a mix bus). Documents go through the store's own encode and decode,
-- so an empty list stays a JSON array.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local ENG = HERE .. ".." .. SEP .. "engine" .. SEP
local V = dofile(ENG .. "rfv_view.lua")
local S = dofile(ENG .. "rfv_store.lua")
local J = S.json

local G = {}
for k = 1, 9 do G[k] = ("{0000000%d-0000-0000-0000-000000000000}"):format(k) end
-- 1 Pre (mix bus), 2 Drums, 3 Kick, 4 Kick in, 5 Kick out, 6 Snare, 7 Bass, 8 Verb (return), 9 Spare
local TRACKS = {
  { guid = G[1], role = "mixbus", group = 0, path = {} },
  { guid = G[2], role = "bus", group = 2, path = { 1 } },
  { guid = G[3], role = "bus", group = 2, path = { 2, 1 } },
  { guid = G[4], role = "source", group = 2, path = { 3, 2, 1 } },
  { guid = G[5], role = "source", group = 2, path = { 3, 2, 1 } },
  { guid = G[6], role = "source", group = 2, path = { 2, 1 } },
  { guid = G[7], role = "source", group = 7, path = { 1 } },
  { guid = G[8], role = "return", group = 8, path = { 1 } },
  { guid = G[9], role = "ignored", group = 0, path = {} },
}

local function roundtrip(doc) return (S.decode(J.encode(doc))) end

local function describe(objs)
  local out = {}
  for i, o in ipairs(objs) do
    local s = o.kind == "group" and ("group:" .. o.name .. "[" .. table.concat(o.members, ",") .. "]") or (o.kind .. ":" .. o.track)
    if o.kind ~= "group" and o.sum then s = s .. "{" .. table.concat(o.sum, ",") .. "}" end
    if o.parent then s = s .. "^" .. o.parent end
    if o.open then s = s .. "+" end
    out[i] = s
  end
  return table.concat(out, " ")
end

return {
  name = "view-logic",
  steps = { function()
    local out, bad = {}, 0
    local function check(what, got, want)
      local ok = got == want
      if not ok then bad = bad + 1 end
      out[#out + 1] = ("  %-52s %s%s"):format(what, tostring(got), ok and "" or ("   <-- want " .. tostring(want)))
    end

    out[#out + 1] = "changes:"
    local doc = S.new_doc()
    V.show(doc, { G[4]:lower(), G[6] })
    doc = roundtrip(doc)
    check("show (GUIDs kept upper-case)", table.concat(doc.view.tracks, ","), G[4] .. "," .. G[6])
    V.add(doc, { G[6], G[7] })
    check("add (no duplicates)", #doc.view.tracks, 3)
    V.remove(doc, { G[6] })
    check("remove", table.concat(doc.view.tracks, ","), G[4] .. "," .. G[7])
    local name = V.group(doc, { G[4], G[5] }, { "Kick in", "Kick out" })
    doc = roundtrip(doc)
    check("group: named from the members", name, "Kick")
    check("group: its tracks are chosen (4, 7 and now 5)", #doc.view.tracks, 3)
    V.group(doc, { G[5], G[6] }, { "Kick out", "Snare" })
    check("a track belongs to one group (moved to the new one)", table.concat(doc.groups[1].tracks, ","), G[4])
    check("a group without a common name", doc.groups[2].name, "Group 2")
    check("rename", V.rename(doc, 2, "  Low end ") and doc.groups[2].name, "Low end")
    V.show(doc, { G[7] })
    doc = roundtrip(doc)
    check("show keeps the groups (decision 4)", #doc.groups, 2)
    V.mode(doc, "toggle")
    check("toggle to all", doc.view.mode, "all")
    V.add(doc, { G[2] })
    check("add switches back to chosen", doc.view.mode, "chosen")
    check("role", V.role(doc, G[8], "source") and doc.roles[G[8]], "source")
    check("role: an unknown one is refused", V.role(doc, G[8], "lead"), false)
    check("role: layer of a GUID (any case)", V.role(doc, G[8], "layer:" .. G[2]:lower()) and doc.roles[G[8]], "layer:" .. G[2])
    V.role(doc, G[8], nil)
    check("role back to the routing's", doc.roles[G[8]], nil)
    V.path(doc, G[7], G[8]:lower())
    check("path", doc.paths[G[7]], G[8])
    V.ungroup(doc, 1)
    check("ungroup", #doc.groups, 1)
    V.forget(doc, { G[6], G[7] })
    doc = roundtrip(doc)
    check("forget: out of the view", table.concat(doc.view.tracks, ","), G[2])
    check("forget: out of groups (an emptied group goes)", doc.groups[1] and table.concat(doc.groups[1].tracks, ",") or "none", G[5])
    check("forget: its path goes", doc.paths and doc.paths[G[7]], nil)
    local empty = S.new_doc()
    V.forget(empty, { G[1] })
    check("an empty view stays a JSON array", (J.encode(empty)):match('"tracks":%[%]') ~= nil, true)

    out[#out + 1] = "group names:"
    local cases = {
      { { "Gtr L", "Gtr R" }, "Gtr" }, { { "BV 1", "BV 2", "BV 5" }, "BV" }, { { "Kick In", "Kick Out" }, "Kick" },
      { { "OH L", "OH R" }, "OH" }, { { "Lead Vox" }, "Lead Vox" }, { { "Bass", "Drums" }, "" },
      { { "Café 1", "Café 2" }, "Café" }, { { "Guitar électrique", "Guitar éclair" }, "Guitar" }, { { "Café A", "Cafè B" }, "" },
      { { "[SUB] Snare", "[SUB] Kick" }, "SUB" }, { { "01_KickMic1", "02_KickMic2" }, "" },
    }
    for _, c in ipairs(cases) do check(table.concat(c[1], " + "), V.common_name(c[1]), c[2]) end

    out[#out + 1] = "stage (track numbers: 1 Pre, 2 Drums, 3 Kick, 4 Kick in, 5 Kick out, 6 Snare, 7 Bass, 8 Verb):"
    local function stage(view_tracks, groups, mode)
      local d = S.new_doc()
      V.show(d, view_tracks)
      for _, g in ipairs(groups or {}) do d.groups[#d.groups + 1] = J.object{ name = g[1], tracks = J.array(g[2]) } end
      if mode then V.mode(d, mode) end
      return describe((V.stage(TRACKS, roundtrip(d))))
    end
    check("one source", stage({ G[4] }), "track:4")
    check("a bus alone: closed", stage({ G[2] }), "bus:2")
    check("a bus with two of its tracks: open", stage({ G[2], G[4], G[6] }), "bus:2+ track:4^1 track:6^1")
    check("nested buses nest", stage({ G[2], G[3], G[4] }), "bus:2+ bus:3^1+ track:4^2")
    check("a track under an unchosen bus stands alone", stage({ G[4], G[6] }), "track:4 track:6")
    check("a display group holds its chosen members", stage({ G[4], G[5], G[7] }, { { "Kicks", { G[4], G[5] } } }), "group:Kicks[4,5]+ track:4^1 track:5^1 track:7")
    check("a group whose members are not chosen is not drawn", stage({ G[7] }, { { "Kicks", { G[4], G[5] } } }), "track:7")
    check("a return", stage({ G[8] }), "return:8")
    check("a GUID of no track is skipped", stage({ G[4], "{DEAD0000-0000-0000-0000-000000000000}" }), "track:4")
    check("mode all: groups under the mix bus", stage({}, nil, "all"), "bus:2 track:7 return:8")
    local objs = V.stage(TRACKS, roundtrip((function() local d = S.new_doc(); V.show(d, { G[4], G[5] })
      d.groups[1] = J.object{ name = "K", tracks = J.array{ G[4], G[5] } }; return d end)()))
    local p = V.object_powers(objs[1], { [4] = { 1, 2 }, [5] = { 3, 4 } })
    check("a group's heard powers add up", p and (p[1] .. "," .. p[2]), "4,6")
    local q = V.object_powers(objs[1], {})
    check("a silent group", q, nil)
    -- step 6 review G1: a group holding a bus and a track inside it counts that track once
    local function group_of(members)
      local d = S.new_doc(); V.show(d, members)
      d.groups[1] = J.object{ name = "G", tracks = J.array(members) }
      return (V.stage(TRACKS, roundtrip(d)))[1]
    end
    local H = { [2] = { 5, 5 }, [3] = { 2, 2 }, [4] = { 1, 1 }, [6] = { 3, 3 }, [7] = { 4, 4 } }
    local g1 = group_of({ G[2], G[4] })
    check("group {Drums, Kick in}: adds up Drums only", table.concat(g1.sum, ","), "2")
    p = V.object_powers(g1, H)
    check("... its powers are the bus's", p and (p[1] .. "," .. p[2]), "5,5")
    local g2 = group_of({ G[3], G[4], G[6] })
    check("group {Kick, Kick in, Snare}: Kick and Snare", table.concat(g2.sum, ","), "3,6")
    local g3 = group_of({ G[6], G[7] })
    p = V.object_powers(g3, H)
    check("group {Snare, Bass}: both", p and (p[1] .. "," .. p[2]), "7,7")

    -- step 6 review U2-a: in mode all every return is its own object, wherever it sits
    out[#out + 1] = "mode all with returns (1 Pre, 2 Drums > 3 Kick + 4 Room, 5 FX > 6 Plate + 7 Hall, 8 Vox, 9 Verb,"
    out[#out + 1] = "  10 Keys > 11 Keys sub > 12 Piano + 13 Keys verb, 10 Keys > 14 Organ):"
    local R = {}
    for k = 1, 14 do R[k] = ("{0000%04d-0000-0000-0000-000000000000}"):format(k) end
    local T2 = {
      { guid = R[1], role = "mixbus", group = 0, path = {} },
      { guid = R[2], role = "bus", group = 2, path = { 1 } },
      { guid = R[3], role = "source", group = 2, path = { 2, 1 } },
      { guid = R[4], role = "return", group = 2, path = { 2, 1 } },
      { guid = R[5], role = "bus", group = 5, path = { 1 } },
      { guid = R[6], role = "return", group = 5, path = { 5, 1 } },
      { guid = R[7], role = "return", group = 5, path = { 5, 1 } },
      { guid = R[8], role = "source", group = 8, path = { 1 } },
      { guid = R[9], role = "return", group = 9, path = { 1 } },
      { guid = R[10], role = "bus", group = 10, path = { 1 } },
      { guid = R[11], role = "bus", group = 10, path = { 10, 1 } },
      { guid = R[12], role = "source", group = 10, path = { 11, 10, 1 } },
      { guid = R[13], role = "return", group = 10, path = { 11, 10, 1 } },
      { guid = R[14], role = "source", group = 10, path = { 10, 1 } },
    }
    local all = S.new_doc(); V.mode(all, "all")
    local o2 = V.stage(T2, roundtrip(all))
    check("objects", describe(o2), "bus:2{3} return:4 return:6 return:7 track:8 return:9 bus:10{12,14} return:13")
    local H2 = { [2] = { 9, 9 }, [3] = { 6, 6 }, [4] = { 3, 3 }, [10] = { 9, 9 }, [12] = { 2, 2 }, [13] = { 3, 3 }, [14] = { 4, 4 } }
    p = V.object_powers(o2[1], H2)
    check("Drums without its room: Kick's powers", p and (p[1] .. "," .. p[2]), "6,6")
    p = V.object_powers(o2[7], H2)
    check("Keys without its verb: Piano + Organ", p and (p[1] .. "," .. p[2]), "6,6")
    check("the original routing (no return inside a group) is unchanged", stage({}, nil, "all"), "bus:2 track:7 return:8")

    -- step 6 review U1: the choices as text and back (the engine's Undo)
    out[#out + 1] = "undo snapshots:"
    local d1 = S.new_doc(); V.show(d1, { G[4], G[7] }); V.group(d1, { G[4], G[5] }, { "Kick in", "Kick out" })
    V.role(d1, G[8], "source"); V.path(d1, G[7], G[8])
    d1 = roundtrip(d1)
    local s1 = V.snapshot(d1)
    local d2 = roundtrip(d1)
    V.show(d2, { G[6] }); V.ungroup(d2, 1); V.mode(d2, "all"); V.role(d2, G[8], nil)
    check("a change changes the snapshot", V.snapshot(d2) ~= s1, true)
    V.restore(d2, s1)
    d2 = roundtrip(d2)
    check("restore: every choice is back", V.snapshot(d2) == s1, true)
    local d3 = roundtrip(d1)
    V.restore(d3, V.snapshot(nil))
    d3 = roundtrip(d3)
    check("restore of 'nothing chosen': an empty view", ("%d tracks, %d groups, %s"):format(#d3.view.tracks, #d3.groups, d3.view.mode), "0 tracks, 0 groups, chosen")
    return bad == 0, table.concat(out, "\n")
  end },
}
