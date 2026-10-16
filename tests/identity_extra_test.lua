-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 1 review, facts the first pass assumed: GUIDs in a project opened as a template,
-- after copy/paste and cut/paste, the master track's GUID, and "Save new version" as a real
-- Save As that the store must follow. Uses REAPER's own clipboard.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")

-- Run an action only if its ID still names the action we mean.
local function act(id, expect)
  local name = reaper.kbd_getTextFromCmd(id, nil) or ""
  if not name:find(expect, 1, true) then error(("action %d is '%s', expected '%s'"):format(id, name, expect)) end
  reaper.Main_OnCommand(id, 0)
end

local function guids(tab)
  local t = {}
  for i = 0, reaper.CountTracks(tab) - 1 do
    local tr = reaper.GetTrack(tab, i)
    local _, nm = reaper.GetTrackName(tr)
    t[#t + 1] = { name = nm, guid = reaper.GetTrackGUID(tr) }
  end
  return t
end

return {
  name = "identity-extra",
  steps = {
    -- 1. a saved project, then the same file opened as a template
    function(tab, ctx)
      ctx.dir = H.tmpdir("Danh tính " .. os.time())
      for i, nm in ipairs({ "A", "B" }) do
        reaper.InsertTrackAtIndex(i - 1, false)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(tab, i - 1), "P_NAME", nm, true)
      end
      ctx.master = reaper.GetTrackGUID(reaper.GetMasterTrack(tab))
      ctx.tpl = ctx.dir .. SEP .. "Template — café.rpp"
      ctx.tab = L.save_reopen(tab, ctx.tpl)
      return nil, "saved Template — café.rpp with tracks A and B"
    end,
    function(tab, ctx)
      local before = guids(tab)
      ctx.gA, ctx.gB = before[1].guid, before[2].guid
      local master_kept = reaper.GetTrackGUID(reaper.GetMasterTrack(tab)) == ctx.master
      reaper.Main_openProject("template:" .. ctx.tpl)
      ctx.tab = reaper.EnumProjects(-1)
      local after = guids(ctx.tab)
      local _, fn = reaper.EnumProjects(-1)
      local same = after[1] and after[1].guid == ctx.gA and after[2].guid == ctx.gB
      ctx.template_same = same
      return true, ("project from template: file name '%s', track GUIDs %s; master GUID %s after reload (%s)"):format(
        fn, same and "SAME as the template" or "NEW", master_kept and "kept" or "changed", ctx.master)
    end,
    -- 2. copy/paste and cut/paste of a track
    function(tab, ctx)
      local A = reaper.GetTrack(tab, 0)
      local gA = reaper.GetTrackGUID(A)
      reaper.SetOnlyTrackSelected(A)
      act(40210, "Copy tracks")
      act(42398, "Paste items/tracks")
      local list = guids(tab)
      local copy_new = #list == 3 and list[2].name == "A" and list[2].guid ~= gA
      local B = reaper.GetTrack(tab, 2)
      local gB = reaper.GetTrackGUID(B)
      reaper.SetOnlyTrackSelected(B)
      act(40337, "Cut tracks")
      reaper.SetOnlyTrackSelected(reaper.GetTrack(tab, 0))
      act(42398, "Paste items/tracks")
      local back
      for _, t in ipairs(guids(tab)) do if t.name == "B" then back = t.guid end end
      return true, ("copy+paste: the copy has a %s GUID; cut+paste: B's GUID %s"):format(
        copy_new and "new" or "SAME", back == gB and "kept" or ("CHANGED (" .. tostring(back) .. ")"))
    end,
    -- 3. Save new version: does the store follow a real Save As?
    function(tab, ctx)
      ctx.ver = ctx.dir .. SEP .. "Bài hát.rpp"
      ctx.tab = L.save_reopen(tab, ctx.ver)
      ctx.st = {}
      S.follow(ctx.tab, ctx.st)
      local g = reaper.GetTrackGUID(reaper.GetTrack(ctx.tab, 0))
      local ok = S.edit(ctx.tab, ctx.st, function(d) d.view.tracks[1] = g end)
      return nil, "Bài hát.rpp with a sidecar written: " .. tostring(ok)
    end,
    function(tab, ctx)
      act(41895, "Save new version of project")
      local _, fn = reaper.EnumProjects(-1)
      local ev = S.follow(tab, ctx.st)
      local side = S.sidecar_path(fn)
      local doc = side and S.read(side)
      return ev == "save-as" and doc ~= nil, ("save new version -> '%s', store: %s, new sidecar readable=%s"):format(
        fn:match("[^/\\]+$") or fn, ev, tostring(doc ~= nil))
    end,
  },
}
