-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 1, two songs from one template share track GUIDs. Opening song B in the tab where
-- song A was open must not count as a Save As of A. A Save As made while the tool was not
-- running is offered back through adoption_candidates; the other song is not offered.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")

local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end

-- Open the template in this tab, put one item from `file` on its first track, save as `path`.
local function song(ctx, file, path)
  reaper.Main_openProject("template:" .. ctx.tpl)
  local t = reaper.EnumProjects(-1)
  L.item(reaper.GetTrack(t, 0), L.env().signals .. SEP .. file, 0, 5)
  return L.save_reopen(t, path)
end

return {
  name = "store-template",
  steps = {
    function(tab, ctx)
      ctx.dir = H.tmpdir("Shared template — café " .. os.time())
      for i, nm in ipairs({ "Vocal", "Guitar" }) do
        reaper.InsertTrackAtIndex(i - 1, false)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(tab, i - 1), "P_NAME", nm, true)
      end
      ctx.tpl = ctx.dir .. SEP .. "Mix template — café.rpp"
      ctx.tab = L.save_reopen(tab, ctx.tpl)
      return nil, "template with Vocal and Guitar"
    end,
    function(tab, ctx)
      ctx.B = ctx.dir .. SEP .. "Bài B.rpp"
      song(ctx, "noise_m20.wav", ctx.B)
      ctx.A = ctx.dir .. SEP .. "Bài A.rpp"
      ctx.tab = song(ctx, "sine1k_m12.wav", ctx.A)
      return nil, "songs A and B made from the template, A open"
    end,
    function(tab, ctx)
      ctx.st = {}
      S.follow(tab, ctx.st)
      local vocal = reaper.GetTrackGUID(reaper.GetTrack(tab, 0))
      S.edit(tab, ctx.st, function(d) d.view.tracks[1] = vocal end)
      reaper.Main_openProject("noprompt:" .. ctx.B) -- B replaces A in the same tab
      ctx.tab = reaper.EnumProjects(-1)
      return nil, "chose Vocal in A, then opened B in the same tab; Vocal GUID shared=" ..
        tostring(reaper.GetTrackGUID(reaper.GetTrack(ctx.tab, 0)) == vocal)
    end,
    function(tab, ctx)
      local ev = S.follow(tab, ctx.st)
      local nothing = slurp(S.sidecar_path(ctx.B)) == nil and ctx.st.doc == nil
      local offers = S.adoption_candidates(tab)
      -- A saved under a new name while the tool was not running
      reaper.Main_openProject("noprompt:" .. ctx.A)
      ctx.A2 = ctx.dir .. SEP .. "Song A — café - version 2.rpp"
      ctx.tab = L.save_reopen(reaper.EnumProjects(-1), ctx.A2)
      ctx.b_ok = ev == "other-project" and nothing and #offers == 0
      return nil, ("open B: %s, nothing copied to B=%s, offers for B=%d"):format(ev, tostring(nothing), #offers)
    end,
    function(tab, ctx)
      local st = {}
      local ev = S.follow(tab, st)
      local offers = S.adoption_candidates(tab)
      local a_offered = offers[1] and offers[1].path == S.sidecar_path(ctx.A) and offers[1].project == "Bài A.rpp"
      return ctx.b_ok and ev == "loaded" and st.doc == nil and #offers == 1 and a_offered,
        ("A saved as 'version 2' with the tool off: %s, choices empty, offers=%d, offered %s (from %s)"):format(
          ev, #offers, offers[1] and offers[1].path:match("[^/\\]+$") or "-", offers[1] and tostring(offers[1].project) or "-")
    end,
  },
}
