-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 9b, method only: where sections come from (engine/rfv_sections.lua), on the kinds of
-- project found among the owner's (step 9 research): regions; one render region over the whole
-- song with the sections as markers (Brauerize, the Tiki Horea template); markers that are notes
-- (OurGoodWolf's "Check Gain Vox"); "#" markers. Nothing plays.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local SC = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_sections.lua")

local function R(pos, rend, name) return { rgn = true, pos = pos, rend = rend, name = name } end
local function Mk(pos, name) return { rgn = false, pos = pos, rend = 0, name = name } end
local function show(list)
  local t = {}
  for _, s in ipairs(list) do t[#t + 1] = ("%s %g-%g"):format(s.name, s.a, s.b) end
  return table.concat(t, ", ")
end

return {
  name = "sections-logic",
  steps = { function()
    local out, bad = {}, 0
    local function check(what, ok, detail)
      if not ok then bad = bad + 1 end
      out[#out + 1] = ("  %-62s %s%s"):format(what, detail, ok and "" or "   <-- FAIL")
    end
    -- OurGoodWolf (the version being mixed): two regions, no markers
    local s, src = SC.build({ R(22, 40, "Verse 1"), R(0, 22, "Intro") }, "regions", 260)
    check("regions: one section each, in order", show(s) == "Intro 0-22, Verse 1 22-40" and src == "regions", show(s))
    -- Brauerize: a render region over the whole song, the sections as plain markers
    local brauerize = { R(0, 249, "song"), Mk(0, "start"), Mk(10, "intro"), Mk(18, "verse 1"), Mk(34, "prechorus 1"), Mk(66, "chorus 1"),
      Mk(78, "link"), Mk(98, "verse 2"), Mk(122, "prechorus 2"), Mk(146, "chorus 2"), Mk(191, "bridge"), Mk(231, "outro"), Mk(249, "end") }
    s, src = SC.build(brauerize, "regions", 249)
    check("a region over the whole song is not a section", #s == 0, ("%d sections (%s)"):format(#s, src))
    s = SC.build(brauerize, "markers", 249)
    check("every marker: twelve markers, the one at the end left out", #s == 11 and s[1].name == "start" and s[11].name == "outro" and s[11].b == 249,
      ("%d: %s ... %s"):format(#s, s[1] and s[1].name or "?", s[#s] and (s[#s].name .. " " .. s[#s].a .. "-" .. s[#s].b) or "?"))
    -- the older OurGoodWolf files: two notes as markers, no regions
    local notes = { Mk(108, "Check Gain Vox"), Mk(178, "Check Gain INS") }
    s = SC.build(notes, "regions", 260)
    check("notes as markers are not sections", #s == 0, ("%d sections"):format(#s))
    -- "#" markers, without regions: used when no region is; the notes still left out
    local hashed = { Mk(0, "#Intro"), Mk(22, "#Verse 1"), Mk(108, "Check Gain Vox"), Mk(130, "# Chorus") }
    s, src = SC.build(hashed, "regions", 200)
    check("no regions: the # markers, each to the next", show(s) == "Intro 0-22, Verse 1 22-130, Chorus 130-200" and src == "markers#", show(s) .. " (" .. src .. ")")
    s = SC.build({ R(0, 30, "A"), Mk(40, "#B") }, "markers#", 100)
    check("# markers chosen: regions left aside", show(s) == "B 40-100", show(s))
    s = SC.build({ Mk(0, "a"), Mk(1, "b"), Mk(10, "c") }, "markers", 20)
    check("every marker: a section under 2 s left out", show(s) == "b 1-10, c 10-20", show(s))
    s = SC.build({ R(0, 30, "A") }, "off", 100)
    check("off: none", #s == 0, "none")
    s = SC.build({ R(0, 10, ""), R(10, 20, "  Chorus  ") }, "something else", 100)
    check("an unknown source reads as regions; names trimmed, unnamed counted", show(s) == "Region 1 0-10, Chorus 10-20", show(s))
    return bad == 0, table.concat(out, "\n")
  end },
}
