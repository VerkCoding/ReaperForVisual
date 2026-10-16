-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 6, live: the five "ReaperForVisual - ..." actions, run the way a user runs them (as
-- actions, from a deferred callback, never inside a bridge command's undo block), with a change
-- of the user's kind pending in the project (a fader set by script, no undo point yet).
-- Temporary copies of the scripts are registered (never the user's), and point the engine ping
-- at the test section. For each action: the choices beside the project are what it should
-- write; the test engine's graph shows it (view and stage) and how soon; the frame carries the
-- action's note; and the project's undo, redo, dirty flag and state counter do not move, with
-- the pending change still pending. Then the tracks are reordered and renamed, saved and opened
-- again: the view still names the same tracks.
-- Tracks: Drums (folder) > Kick, Snare; Bass; Vox.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json
local SCRIPTS = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(SCRIPTS .. "rfv_store.lua")

local ACTIONS = {
  show = "ReaperForVisual - Show selected tracks.lua", add = "ReaperForVisual - Add selected tracks.lua",
  remove = "ReaperForVisual - Remove selected tracks.lua", group = "ReaperForVisual - Group selected tracks.lua",
  all = "ReaperForVisual - Show all or chosen tracks.lua",
}

local function launcher(op)
  local d = (os.getenv("TEMP") or "/tmp") .. SEP .. "rfv-tests" .. SEP .. "launchers"
  reaper.RecursiveCreateDirectory(d, 0)
  local path = d .. SEP .. "rfv_view_" .. op .. ".lua"
  local f = assert(io.open(path, "wb"))
  f:write(("_G.RFV_SECTION = %q\ndofile([[%s]])\n"):format(EL.SECTION, SCRIPTS .. ACTIONS[op]))
  f:close()
  return reaper.AddRemoveReaScript(true, 0, path, true), path
end

local function names_of(P, guids)
  local by = {}
  for i = 0, reaper.CountTracks(P) - 1 do
    local tr = reaper.GetTrack(P, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    by[reaper.GetTrackGUID(tr)] = nm
  end
  local out = {}
  for i, g in ipairs(guids or {}) do out[i] = by[tostring(g):upper()] or ("?" .. tostring(g)) end
  table.sort(out)
  return table.concat(out, ",")
end

local function stage_text(g)
  if not g or not g.stage then return "-" end
  local out = {}
  for i, o in ipairs(g.stage.objects) do
    local s = o.kind == "group" and ("group " .. tostring(o.name)) or (o.kind .. " " .. (g.tracks[o.track + 1].name or "?"))
    if o.parent ~= J.null then s = s .. "^" .. (o.parent + 1) end
    if o.open then s = s .. "+" end
    out[i] = s
  end
  return g.stage.mode .. ": " .. table.concat(out, ", ")
end

return {
  name = "view-actions",
  cleanup = function(ctx)
    EL.stop()
    for op in pairs(ctx.paths or {}) do EL.unregister(ctx.paths[op]) end
    if ctx.epath then EL.unregister(ctx.epath) end
  end,
  steps = {
    function(tab, ctx)
      local sine = L.env().signals .. SEP .. "sine1k_m12.wav"
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      L.track(tab, "Drums", 1)
      L.item(L.track(tab, "Kick", 0), sine, 0, 30)
      L.item(L.track(tab, "Snare", -1), sine, 0, 30)
      L.item(L.track(tab, "Bass", 0), sine, 0, 30)
      L.item(L.track(tab, "Vox", 0), sine, 0, 30)
      ctx.rpp = H.tmpdir("view-actions") .. SEP .. "va.rpp"
      local side = S.sidecar_path(ctx.rpp) -- choices a previous run left beside it
      for _, x in ipairs({ side, side .. ".tmp", side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, ctx.rpp)
      ctx.cmds, ctx.paths = {}, {}
      for op in pairs(ACTIONS) do ctx.cmds[op], ctx.paths[op] = launcher(op) end
      EL.reset()
      -- the test engine keeps the light of this test's own "all" launcher (step 6 review, U3)
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_view", ctx.cmds.all)
      EL.run_later(ctx.ecmd)
      local P = ctx.tab
      local tr = {}
      for i = 0, reaper.CountTracks(P) - 1 do
        local t = reaper.GetTrack(P, i)
        local _, nm = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
        tr[nm] = t
      end
      local R = { probes = {}, ticks = {} }
      _G.RFV_VA = R
      local function select(list)
        reaper.SetOnlyTrackSelected(reaper.GetMasterTrack(P)) -- clears the tracks' selection
        reaper.SetTrackSelected(reaper.GetMasterTrack(P), false)
        for _, nm in ipairs(list) do reaper.SetTrackSelected(tr[nm], true) end
      end
      local function probe(label)
        local ok, redo = pcall(reaper.Undo_CanRedo2, P)
        local doc = S.read(S.sidecar_path(ctx.rpp))
        local f = EL.read("frame")
        R.probes[#R.probes + 1] = { label = label, t = reaper.time_precise(), undo = tostring(reaper.Undo_CanUndo2(P)), redo = tostring(ok and redo),
          dirty = reaper.IsProjectDirty(P), sc = reaper.GetProjectStateChangeCount(P), vol = reaper.GetMediaTrackInfo_Value(tr.Bass, "D_VOL"),
          view = doc and names_of(P, doc.view.tracks) or "-", mode = doc and doc.view.mode or "-",
          groups = doc and #doc.groups or 0, gname = doc and doc.groups[1] and doc.groups[1].name or "-",
          note = f and f.note ~= J.null and f.note or "-" }
      end
      local function act(op) R.ran = R.ran or {}; R.ran[#R.ran + 1] = { op = op, t = reaper.time_precise() }; reaper.Main_OnCommand(ctx.cmds[op], 0) end
      local function pings() return tonumber((reaper.GetExtState(EL.SECTION, "ping"):match("^(%d+)"))) or 0 end
      R.lights = {}
      local function light(label) R.lights[#R.lights + 1] = { label = label, state = reaper.GetToggleCommandStateEx(0, ctx.cmds.all) } end
      -- a command from the page, as the web interface stores it
      local seq = 5000
      local function page(obj)
        seq = seq + 1
        obj.tab = tostring(P)
        local body = J.encode(J.object(obj))
        reaper.SetExtState(EL.SECTION, "cmd", ("%d|%d|%s"):format(seq, #body, body), false)
      end
      -- another program changes the mode in the file: only the engine can follow with the light
      local function mode_in_file(m) S.edit(P, {}, function(doc) doc.view.mode = m end) end
      local plan = {
        { 1.5, function() reaper.SetMediaTrackInfo_Value(tr.Bass, "D_VOL", 0.5) end }, -- the pending change (engine running by now)
        { 0.2, function() select({ "Kick", "Snare" }) end },
        { 0.2, function() probe("before show") end },
        { 0.0, function() act("show") end },
        { 0.6, function() probe("after show (Kick, Snare)") end },
        { 0.0, function() select({ "Drums" }) end },
        { 0.2, function() probe("before add") end },
        { 0.0, function() act("add") end },
        { 0.6, function() probe("after add (Drums)") end },
        { 0.0, function() select({ "Kick", "Snare" }) end },
        { 0.2, function() probe("before group") end },
        { 0.0, function() act("group") end },
        { 0.6, function() probe("after group (Kick, Snare)") end },
        { 0.0, function() select({ "Drums" }) end },
        { 0.2, function() probe("before remove") end },
        { 0.0, function() act("remove") end },
        { 0.6, function() probe("after remove (Drums)") end },
        { 0.0, function() probe("before all"); light("before all") end },
        { 0.0, function() act("all") end },
        { 0.6, function() probe("after all"); light("after all (the action)") end },
        { 0.0, function() select({}) end },
        { 0.2, function() probe("before show, nothing selected") end },
        { 0.0, function() act("show") end },
        { 0.6, function() probe("after show, nothing selected") end },
        { 0.0, function() act("all") end },
        { 0.6, function() probe("after all again"); light("after all again (the action)") end },
        -- U3: the engine keeps the light in step when the mode changes elsewhere
        { 0.0, function() mode_in_file("all") end },
        { 1.6, function() light("mode all written by another program (the engine)") end },
        { 0.0, function() mode_in_file("chosen") end },
        { 1.6, function() light("mode chosen written by another program (the engine)") end },
        -- G2: an action run twice before its first run's last defer (a held shortcut): no dialog,
        -- both runs done
        { 0.0, function() select({ "Bass" }) end },
        { 0.2, function() probe("before add twice") end },
        { 0.0, function() R.p0 = pings(); act("add"); act("add") end },
        { 0.6, function() R.twice = pings() - R.p0; probe("after add twice (Bass)") end },
        { 0.0, function() act("remove") end },
        { 0.6, function() probe("after remove (Bass)") end },
        -- U1: the page's Undo takes back an action's change, Redo makes it again
        { 0.0, function() page({ op = "undo" }) end },
        { 0.6, function() probe("after page undo") end },
        { 0.0, function() page({ op = "redo" }) end },
        { 0.6, function() probe("after page redo") end },
      }
      local i, t_next = 1, reaper.time_precise() + plan[1][1]
      local function run()
        if not reaper.ValidatePtr2(0, P, "ReaProject*") then R.gone = true; return end -- the harness closed the tab
        local now = reaper.time_precise()
        local g = EL.read("graph")
        R.ticks[#R.ticks + 1] = { t = now, gseq = g and g.gseq or -1 }
        if now >= t_next then
          plan[i][2]()
          i = i + 1
          if not plan[i] then R.done = true; return end
          t_next = now + plan[i][1]
        end
        reaper.defer(run)
      end
      reaper.defer(run)
      return nil, "built, saved, launchers registered, engine started; actions scheduled", 16
    end,
    function(tab, ctx)
      local R = _G.RFV_VA
      if not R.done then
        local last = R.probes[#R.probes]
        return false, ("the scenario did not finish: %d probes, the last '%s'; %d actions run; engine error: %s"):format(#R.probes,
          last and last.label or "-", #(R.ran or {}), reaper.GetExtState(EL.SECTION, "error"))
      end
      local out, ok = {}, true
      local want = {
        ["after show (Kick, Snare)"] = { "Kick,Snare", "chosen", 0 },
        ["after add (Drums)"] = { "Drums,Kick,Snare", "chosen", 0 },
        ["after group (Kick, Snare)"] = { "Drums,Kick,Snare", "chosen", 1 },
        ["after remove (Drums)"] = { "Kick,Snare", "chosen", 1 },
        ["after all"] = { "Kick,Snare", "all", 1 },
        ["after show, nothing selected"] = { "Kick,Snare", "all", 1 },
        ["after all again"] = { "Kick,Snare", "chosen", 1 },
        ["after add twice (Bass)"] = { "Bass,Kick,Snare", "chosen", 1 },
        ["after remove (Bass)"] = { "Kick,Snare", "chosen", 1 },
        ["after page undo"] = { "Bass,Kick,Snare", "chosen", 1 },
        ["after page redo"] = { "Kick,Snare", "chosen", 1 },
      }
      local prev
      for _, p in ipairs(R.probes) do
        local w = want[p.label]
        local good = true
        if w then good = p.view == w[1] and p.mode == w[2] and p.groups == w[3] end
        -- an action must leave the project as the probe before it found it
        if p.label:find("^after") and prev then
          good = good and p.undo == prev.undo and p.redo == prev.redo and p.dirty == prev.dirty and p.sc == prev.sc and p.vol == 0.5
        end
        if not good then ok = false end
        out[#out + 1] = ("  %-30s view %-18s mode %-6s groups %d (%s) | undo=%s dirty=%d sc=%d vol=%.2f | note: %s%s"):format(p.label, p.view, p.mode, p.groups,
          p.gname, p.undo, p.dirty, p.sc, p.vol, p.note, good and "" or "  <-- FAIL")
        prev = p
      end
      -- how soon the engine's graph showed each change
      local lat = {}
      for _, r in ipairs(R.ran or {}) do
        local g0
        for _, tk in ipairs(R.ticks) do
          if tk.t < r.t then g0 = tk.gseq
          elseif g0 and tk.gseq > g0 then lat[#lat + 1] = ("%s %.0f ms"):format(r.op, 1000 * (tk.t - r.t)); break end
        end
      end
      out[#out + 1] = "  graph updated after: " .. table.concat(lat, ", ") .. " (the empty selection changes nothing, so no update)"
      local twice_ok = R.twice == 2
      if not twice_ok then ok = false end
      out[#out + 1] = ("  add run twice in one tick: %s runs done, no dialog%s"):format(tostring(R.twice), twice_ok and "" or "  <-- FAIL (want 2)")
      local want_light = { 0, 1, 0, 1, 0 }
      for j, l in ipairs(R.lights) do
        local good = l.state == want_light[j]
        if not good then ok = false end
        out[#out + 1] = ("  light %-52s %d%s"):format(l.label, l.state, good and "" or ("  <-- FAIL (want " .. tostring(want_light[j]) .. ")"))
      end
      local g = EL.read("graph")
      ctx.stage_before = stage_text(g)
      out[#out + 1] = "  stage now: " .. ctx.stage_before
      if ctx.stage_before ~= "chosen: group Group 1+, track Kick^1, track Snare^1" then ok = false; out[#out] = out[#out] .. "  <-- FAIL" end
      ctx.ok = ok
      -- now reorder (Vox to the top) and rename (Kick -> Kick In), save, open again
      local P = ctx.tab
      local vox
      for i = 0, reaper.CountTracks(P) - 1 do
        local t = reaper.GetTrack(P, i)
        local _, nm = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
        if nm == "Vox" then vox = t end
        if nm == "Kick" then reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "Kick In", true) end
      end
      reaper.SetOnlyTrackSelected(vox)
      reaper.ReorderSelectedTracks(0, 0)
      ctx.tab = L.save_reopen(P, ctx.rpp)
      ctx.out = out
      return nil, table.concat(out, "\n"), 2
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local after = stage_text(g)
      local good = after == "chosen: group Group 1+, track Kick In^1, track Snare^1"
      local first = g and g.tracks[1] and g.tracks[1].name
      EL.stop()
      for op in pairs(ACTIONS) do EL.unregister(ctx.paths[op]) end
      EL.unregister(ctx.epath)
      return ctx.ok and good and first == "Vox", ("after reorder (first track now %s), rename and reopen: %s%s"):format(tostring(first), after, good and "" or "  <-- FAIL")
    end,
  },
}
