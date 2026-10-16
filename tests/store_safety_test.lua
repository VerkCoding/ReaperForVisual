-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 1, storage safety: two writers, a file changed by another program, a damaged file
-- when ".bad" is taken, a write cut short (.tmp and .old), a file from a newer version,
-- a file that cannot be written, a foreign file, GUID case and tracks that are gone.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")

local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function put(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end

return {
  name = "store-safety",
  steps = {
    function(tab, ctx)
      ctx.dir = H.tmpdir("An toàn " .. os.time())
      for i = 1, 3 do reaper.InsertTrackAtIndex(i - 1, false) end
      ctx.g = {}
      for i = 0, 2 do ctx.g[i + 1] = reaper.GetTrackGUID(reaper.GetTrack(tab, i)) end
      ctx.path = ctx.dir .. SEP .. "Check — café.rpp"
      ctx.side = S.sidecar_path(ctx.path)
      ctx.tab = L.save_reopen(tab, ctx.path)
      return nil, "saved Check — café.rpp with 3 tracks"
    end,
    -- two writers and another program
    function(tab, ctx)
      local e, a = {}, {}
      S.follow(tab, e); S.follow(tab, a)
      S.edit(tab, a, function(d) d.view.tracks[#d.view.tracks + 1] = ctx.g[1] end)
      S.edit(tab, e, function(d) d.view.tracks[#d.view.tracks + 1] = ctx.g[2] end) -- e's cache is stale
      local both = table.concat(S.read(ctx.side).view.tracks, ",") == ctx.g[1] .. "," .. ctx.g[2]
      local ev = S.follow(tab, a)
      put(ctx.side, (slurp(ctx.side):gsub('"format"', '"note": "from another program",\n  "format"', 1)))
      local ev2 = S.follow(tab, e)
      S.edit(tab, e, function(d) d.view.tracks[#d.view.tracks + 1] = ctx.g[3] end)
      local doc = S.read(ctx.side)
      local kept = doc.note == "from another program" and #doc.view.tracks == 3
      return both and ev == "reloaded" and ev2 == "reloaded" and kept,
        ("two writers keep both changes=%s; other script %s; external change %s and kept after an edit=%s"):format(
          tostring(both), ev, ev2, tostring(kept))
    end,
    -- a write cut short
    function(tab, ctx)
      local good = slurp(ctx.side)
      os.remove(ctx.side); put(ctx.side .. ".tmp", good)
      local st = {}
      local ev = S.follow(tab, st)
      local from_tmp = st.recovered_from == ctx.side .. ".tmp" and slurp(ctx.side) == good and #st.doc.view.tracks == 3
      os.remove(ctx.side); os.remove(ctx.side .. ".tmp"); put(ctx.side .. ".old", good)
      local st2 = {}
      S.follow(tab, st2)
      local from_old = st2.recovered_from == ctx.side .. ".old" and slurp(ctx.side) == good and not reaper.file_exists(ctx.side .. ".old")
      local ev3 = S.follow(tab, st2)
      return ev == "loaded" and from_tmp and from_old and ev3 == "same",
        ("cut-short write: recovered from .tmp=%s, from .old=%s (restored, .old removed), next look %s"):format(
          tostring(from_tmp), tostring(from_old), ev3)
    end,
    -- damaged while ".bad" is already taken
    function(tab, ctx)
      put(ctx.side .. ".bad", "an older damaged file")
      put(ctx.side, "{broken")
      local st = {}
      S.follow(tab, st)
      local reported = st.error and st.error.code == "damaged"
      local ok = S.edit(tab, st, function(d) d.view.tracks[1] = ctx.g[1] end)
      local older_intact = slurp(ctx.side .. ".bad") == "an older damaged file"
      local kept = st.kept_as and slurp(st.kept_as) == "{broken"
      local fresh = S.read(ctx.side) ~= nil
      return reported and ok and older_intact and kept and fresh,
        ("damaged: reported=%s; after a change the older .bad is intact=%s, this one kept as %s=%s, new file readable=%s"):format(
          tostring(reported), tostring(older_intact), tostring(st.kept_as and st.kept_as:match("[^/\\]+$")), tostring(kept), tostring(fresh))
    end,
    -- a file from a newer version is never written
    function(tab, ctx)
      local newer = '{"format":"rfv","version":7,"view":{"tracks":[]},"something":"new"}'
      put(ctx.side, newer)
      local st = {}
      S.follow(tab, st)
      local ro = st.error and st.error.code == "newer"
      local ok, err = S.edit(tab, st, function(d) d.view.tracks[1] = ctx.g[1] end)
      local same = slurp(ctx.side) == newer
      return ro and not ok and same, ("newer version: read only=%s, edit refused=%s (%s), file unchanged=%s"):format(
        tostring(ro), tostring(not ok), err and err.msg or "-", tostring(same))
    end,
    -- a file that cannot be written: a folder squats on the temporary name, then on .old
    function(tab, ctx)
      os.remove(ctx.side)
      reaper.RecursiveCreateDirectory(ctx.side .. ".tmp", 0)
      local st = {}
      S.follow(tab, st)
      local ok, err = S.edit(tab, st, function(d) d.view.tracks[1] = ctx.g[1] end)
      local failed = not ok and err.code == "write-failed" and st.error and st.error.code == "write-failed" and not reaper.file_exists(ctx.side)
      -- a file exists, and .old cannot be made
      ctx.side2 = S.sidecar_path(ctx.dir .. SEP .. "Hai.rpp")
      ctx.tab = L.save_reopen(tab, ctx.dir .. SEP .. "Hai.rpp")
      ctx.failed1, ctx.msg1 = failed, err and err.msg
      return nil, "write blocked by a folder named .tmp: " .. tostring(failed)
    end,
    function(tab, ctx)
      local st = {}
      S.follow(tab, st)
      S.edit(tab, st, function(d) d.view.tracks[1] = ctx.g[1] end)
      local before = slurp(ctx.side2)
      reaper.RecursiveCreateDirectory(ctx.side2 .. ".old", 0)
      local ok, err = S.edit(tab, st, function(d) d.view.tracks[2] = ctx.g[2] end)
      local intact = slurp(ctx.side2) == before and not reaper.file_exists(ctx.side2 .. ".tmp")
      return ctx.failed1 and not ok and intact, ("cannot write: .tmp blocked reported=%s; .old blocked reported=%s and the old file intact=%s (%s)"):format(
        tostring(ctx.failed1), tostring(not ok), tostring(intact), err and err.msg or "-")
    end,
    -- a foreign file; GUID case; tracks that are gone
    function(tab, ctx)
      local side3 = S.sidecar_path(ctx.dir .. SEP .. "Ba.rpp")
      put(side3, '{"format":"something else"}')
      ctx.tab = L.save_reopen(tab, ctx.dir .. SEP .. "Ba.rpp")
      ctx.side3 = side3
      return nil, "foreign file beside Ba.rpp"
    end,
    function(tab, ctx)
      local st = {}
      S.follow(tab, st)
      local foreign = st.error and st.error.code == "foreign"
      S.edit(tab, st, function(d) d.view.tracks = { ctx.g[1]:lower(), ctx.g[3] } end)
      local doc = S.read(ctx.side3)
      local upper = doc.view.tracks[1] == ctx.g[1]
      local none_missing = #S.missing(doc, tab) == 0
      reaper.DeleteTrack(reaper.GetTrack(tab, 2))
      local miss = S.missing(doc, tab)
      return foreign and st.kept_as ~= nil and upper and none_missing and #miss == 1 and has(miss, ctx.g[3]),
        ("foreign file reported=%s and kept aside=%s; lower-case GUID stored upper=%s; missing before=%d, after deleting a track=%d"):format(
          tostring(foreign), tostring(st.kept_as ~= nil), tostring(upper), none_missing and 0 or -1, #miss)
    end,
  },
}
