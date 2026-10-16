-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 1 gate, identity: a track's GUID survives rename, reorder, save and reload (on a path
-- with Vietnamese characters), delete followed by undo; a duplicated track gets a new GUID.

local SEP = package.config:sub(1, 1)
local H = dofile(debug.getinfo(1, "S").source:match("^@(.*[/\\])") .. "harness.lua")

local function by_name(tab)
  local m = {}
  for i = 0, reaper.CountTracks(tab) - 1 do
    local tr = reaper.GetTrack(tab, i)
    local _, nm = reaper.GetTrackName(tr)
    m[nm] = reaper.GetTrackGUID(tr)
  end
  return m
end

return {
  name = "identity",
  steps = {
    -- 1. three tracks, rename one, move one, save to a Vietnamese path and reopen
    function(tab, ctx)
      for i, nm in ipairs({ "A", "B", "C" }) do
        reaper.InsertTrackAtIndex(i - 1, false)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(tab, i - 1), "P_NAME", nm, true)
      end
      local g = by_name(tab)
      ctx.guid = { A = g.A, B = g.B, C = g.C }
      reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(tab, 1), "P_NAME", "B renamed — café", true)
      reaper.SetOnlyTrackSelected(reaper.GetTrack(tab, 0))
      reaper.ReorderSelectedTracks(3, 0) -- A moves to the end
      local _, last = reaper.GetTrackName(reaper.GetTrack(tab, 2))
      local g2 = by_name(tab)
      local ok = last == "A" and g2.A == ctx.guid.A and g2["B renamed — café"] == ctx.guid.B and g2.C == ctx.guid.C
      ctx.path = H.tmpdir("Test SOUND — café") .. SEP .. "Project — naïve 1.rpp"
      reaper.Main_SaveProjectEx(tab, ctx.path, 0)
      reaper.Main_openProject("noprompt:" .. ctx.path)
      ctx.tab = reaper.EnumProjects(-1)
      return ok, ("rename+reorder keep GUIDs: %s (A now last: %s)"):format(tostring(ok), tostring(last == "A"))
    end,
    -- 2. after reload from the Vietnamese path: same file name, same GUIDs; then delete B
    function(tab, ctx)
      local _, fn = reaper.EnumProjects(-1)
      local g = by_name(tab)
      local ok = fn == ctx.path and g.A == ctx.guid.A and g["B renamed — café"] == ctx.guid.B and g.C == ctx.guid.C
      local detail = ("reload: file name matches=%s, GUIDs kept=%s, dirty=%d"):format(tostring(fn == ctx.path),
        tostring(g.A == ctx.guid.A and g["B renamed — café"] == ctx.guid.B and g.C == ctx.guid.C), reaper.IsProjectDirty(tab))
      reaper.DeleteTrack(reaper.GetTrack(tab, 0)) -- "B renamed — café" is first after the move
      return ok and reaper.CountTracks(tab) == 2, detail .. "; deleted B, tracks=" .. reaper.CountTracks(tab)
    end,
    -- 3. undo brings B back with its GUID; a duplicate gets a new GUID
    function(tab, ctx)
      local top = reaper.Undo_CanUndo2(tab)
      reaper.Main_OnCommand(40029, 0) -- Edit: Undo
      local g = by_name(tab)
      local back = g["B renamed — café"] == ctx.guid.B
      reaper.SetOnlyTrackSelected(reaper.GetTrack(tab, reaper.CountTracks(tab) - 1))
      reaper.Main_OnCommand(40062, 0) -- Track: Duplicate tracks
      local dup = reaper.GetTrack(tab, reaper.CountTracks(tab) - 1)
      local dg = reaper.GetTrackGUID(dup)
      local _, dn = reaper.GetTrackName(dup)
      local fresh = dg ~= ctx.guid.A and dg ~= ctx.guid.B and dg ~= ctx.guid.C
      return back and fresh, ("undo of '%s': B back with same GUID=%s; duplicate '%s' has a new GUID=%s"):format(
        tostring(top), tostring(back), dn, tostring(fresh))
    end,
  },
}
