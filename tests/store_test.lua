-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 1, storage life cycle: an unsaved project shared by two scripts through ExtState,
-- the first save (with and without the engine running), Save As, a backup file, unknown
-- keys and labels, on paths with Vietnamese characters. The project itself never changes.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")

local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function put(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function view(doc) return doc and table.concat(doc.view.tracks, ",") or "nil" end

-- S.follow and S.edit must leave the project exactly as it was.
local function untouched(tab, f)
  local d0, c0, u0 = reaper.IsProjectDirty(tab), reaper.GetProjectStateChangeCount(tab), reaper.Undo_CanUndo2(tab)
  local a, b = f()
  return a, b, reaper.IsProjectDirty(tab) == d0 and reaper.GetProjectStateChangeCount(tab) == c0 and reaper.Undo_CanUndo2(tab) == u0
end

return {
  name = "store",
  steps = {
    -- 1. unsaved: the action writes, the engine sees it; nothing on disk
    function(tab, ctx)
      ctx.dir = H.tmpdir("Storage — café " .. os.time())
      for i, nm in ipairs({ "Drums — café", "Bass" }) do
        reaper.InsertTrackAtIndex(i - 1, false)
        reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(tab, i - 1), "P_NAME", nm, true)
      end
      L.item(reaper.GetTrack(tab, 0), L.env().signals .. SEP .. "sine1k_m12.wav", 0, 5)
      ctx.g1, ctx.g2 = reaper.GetTrackGUID(reaper.GetTrack(tab, 0)), reaper.GetTrackGUID(reaper.GetTrack(tab, 1))
      ctx.engine, ctx.action = {}, {}
      local ev0 = S.follow(tab, ctx.engine)
      S.follow(tab, ctx.action)
      local ok, _, clean = untouched(tab, function() return S.edit(tab, ctx.action, function(d) d.view.tracks[1] = ctx.g1 end) end)
      local ev1 = S.follow(tab, ctx.engine)
      local shared = view(ctx.engine.doc) == ctx.g1
      ctx.key = S.tab_key(tab)
      local in_ext = reaper.GetExtState(S.EXT_SECTION, ctx.key) ~= ""
      ctx.p1 = ctx.dir .. SEP .. "Saved project — café.rpp"
      ctx.ptr = tostring(tab)
      ctx.tab = L.save_reopen(tab, ctx.p1)
      local pass = ok and ev0 == "loaded" and ev1 == "reloaded" and shared and in_ext and clean
      return pass, ("unsaved: engine %s, action edit %s, engine %s and sees it=%s, kept in ExtState=%s, project untouched=%s"):format(
        ev0, tostring(ok), ev1, tostring(shared), tostring(in_ext), tostring(clean))
    end,
    -- 2. first save with the engine running: the choices move into the sidecar
    function(tab, ctx)
      local ev, _, clean = untouched(tab, function() return S.follow(tab, ctx.engine) end)
      local doc = S.read(S.sidecar_path(ctx.p1))
      local ext_cleared = reaper.GetExtState(S.EXT_SECTION, ctx.key) == ""
      local labelled = doc and doc.labels and doc.labels[ctx.g1] == "Drums — café" and doc.project == "Saved project — café.rpp"
      -- Another follower may get there first: an engine the user is running follows the active
      -- tab (this one) and can move the choices between the two bridge commands. Then this one
      -- finds them already beside the file ("loaded-existing"), which is right too.
      local pass = (ev == "first-save" or ev == "loaded-existing") and doc and view(doc) == ctx.g1 and ext_cleared and labelled and clean
      return pass, ("first save (engine running): %s, sidecar view ok=%s, ExtState cleared=%s, label '%s', project untouched=%s, tab pointer kept=%s"):format(
        ev, tostring(doc and view(doc) == ctx.g1), tostring(ext_cleared), doc and doc.labels and tostring(doc.labels[ctx.g1]) or "-",
        tostring(clean), tostring(tostring(tab) == ctx.ptr))
    end,
    -- 3. Save As copies; later edits go to the new file only; unknown keys survive
    function(tab, ctx)
      ctx.p2 = ctx.dir .. SEP .. "Saved project — café - version 2.rpp"
      ctx.tab = L.save_reopen(tab, ctx.p2)
      return nil, "saved as Saved project — café - version 2.rpp"
    end,
    function(tab, ctx)
      local ev = S.follow(tab, ctx.engine)
      local s1, s2 = S.sidecar_path(ctx.p1), S.sidecar_path(ctx.p2)
      local copied = view(S.read(s2)) == ctx.g1
      S.edit(tab, ctx.engine, function(d) d.view.tracks[2] = ctx.g2 end)
      local new2, old1 = view(S.read(s2)) == ctx.g1 .. "," .. ctx.g2, view(S.read(s1)) == ctx.g1
      put(s2, (slurp(s2):gsub('"format"', '"future": {"x": 1},\n  "format"', 1)))
      local fresh = {}
      local ev3 = S.follow(tab, fresh)
      S.edit(tab, fresh, function(d) table.remove(d.view.tracks, 1) end)
      local kept = S.read(s2)
      local future = kept and kept.future and kept.future.x == 1 and view(kept) == ctx.g2
      -- as in step 2: an engine the owner runs follows this tab too, and may copy the choices to
      -- the new name first, so this follow finds them there ("loaded-existing", seen 2026-10-14)
      local pass = (ev == "save-as" or ev == "loaded-existing") and copied and new2 and old1 and ev3 == "loaded" and future
      return pass, ("save as: %s copied=%s; edit: new file 2 tracks=%s, old file still 1=%s; restart %s, unknown key kept=%s"):format(
        ev, tostring(copied), tostring(new2), tostring(old1), ev3, tostring(future))
    end,
    -- 4. first save while the engine was not running: found again in ExtState
    function(tab, ctx)
      reaper.Main_OnCommand(40859, 0) -- a new unsaved project tab of our own
      local t2 = reaper.EnumProjects(-1)
      reaper.InsertTrackAtIndex(0, false)
      L.item(reaper.GetTrack(t2, 0), L.env().signals .. SEP .. "noise_m20.wav", 0, 5)
      local a = {}
      S.follow(t2, a)
      S.edit(t2, a, function(d) d.view.mode = "all" end) -- names no track: matched by its items
      ctx.p3 = ctx.dir .. SEP .. "New — café.rpp"
      t2 = L.save_reopen(t2, ctx.p3)
      local late = {}
      local ev = S.follow(t2, late)
      local doc = S.read(S.sidecar_path(ctx.p3))
      local pass = ev == "first-save" and doc and doc.view.mode == "all"
      reaper.Main_OnCommand(40860, 0) -- close our extra tab, clean after the reopen
      reaper.SelectProjectInstance(tab)
      return pass, ("first save, engine started afterwards: %s, mode kept '%s'"):format(ev, doc and doc.view.mode or "-")
    end,
    -- 5. a backup file: shown, not written; a user change there does write
    function(tab, ctx)
      ctx.bk = ctx.dir .. SEP .. "Backups" .. SEP .. "Saved project — café - version 2-2026-10-11_1200.rpp"
      ctx.tab = L.save_reopen(tab, ctx.bk)
      return nil, "opened a timestamped backup"
    end,
    function(tab, ctx)
      local ev = S.follow(tab, ctx.engine)
      local side = S.sidecar_path(ctx.bk)
      local none = slurp(side) == nil
      local shown = ctx.engine.doc ~= nil
      local ok = S.edit(tab, ctx.engine, function(d) d.sections.source = "markers#" end)
      local written = slurp(side) ~= nil
      return ev == "save-as-backup" and none and shown and ok and written,
        ("backup: %s, nothing written=%s, still shown=%s; after a user change written=%s"):format(ev, tostring(none), tostring(shown), tostring(written))
    end,
  },
}
