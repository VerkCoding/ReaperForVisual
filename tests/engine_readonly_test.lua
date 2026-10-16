-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 3 gate: the engine is read only. The project holds a change that is not in its undo
-- history yet (as after a user's plugin tweak); the engine is started as an action, runs
-- while stopped and while playing (master muted, so nothing is heard), and is stopped. The
-- dirty flag, undo, redo and the state counter must not move. Everything happens in deferred
-- callbacks between two bridge commands, because a bridge command would itself sweep the
-- pending change into an undo point.
--   python tools/rfv_test.py tests/engine_readonly_test.lua --set seconds=600   (the gate)
--   default 60 s
-- Since step 9b the project has two regions and a page counts as open all along, so the engine
-- also works out the sections' average stages (only while a page looks).

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")

local SECONDS = tonumber((_G.RFV_ARGS or {}).seconds) or 60
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local ST = dofile(ENG .. "rfv_store.lua")
local VW = dofile(ENG .. "rfv_view.lua")

return {
  name = "engine-readonly-" .. SECONDS .. "s",
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      for i, nm in ipairs({ "Sine", "Noise", "Stereo" }) do L.track(tab, nm, 0) end
      local S = L.env().signals .. SEP
      L.item(reaper.GetTrack(tab, 0), S .. "sine1k_m12.wav", 0, 30)
      L.item(reaper.GetTrack(tab, 1), S .. "noise_m20.wav", 0, 30)
      L.item(reaper.GetTrack(tab, 2), S .. "st_500L_3kR.wav", 0, 30)
      -- REAPER may stop at the end of the project; loop the 30 s instead, so it plays all along
      reaper.GetSet_LoopTimeRange2(tab, true, true, 0, 30, false)
      reaper.GetSetRepeatEx(tab, 1)
      reaper.AddProjectMarker2(tab, true, 0, 15, "A", -1, 0)
      reaper.AddProjectMarker2(tab, true, 15, 30, "B", -1, 0)
      local rpp = H.tmpdir("readonly") .. SEP .. "readonly.rpp"
      local side = ST.sidecar_path(rpp)
      for _, x in ipairs({ side, side .. ".tmp", side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, rpp)
      -- step 7: the whole mix is shown, so the engine also reads every track's files for Y and
      -- width all along (the choices live beside the project, not in it)
      ST.edit(ctx.tab, {}, function(doc) VW.mode(doc, "all") end)
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_ro")
      return nil, "3 tracks with audio, two regions, master muted, saved clean, the whole mix shown; launcher registered"
    end,
    function(tab, ctx)
      local T, tr = tab, reaper.GetTrack(tab, 0)
      local R = { probes = {} }
      _G.RFV_RO = R
      local function probe(label)
        local ok, redo = pcall(reaper.Undo_CanRedo2, T)
        R.probes[#R.probes + 1] = { label = label, undo = tostring(reaper.Undo_CanUndo2(T)), redo = tostring(ok and redo),
          dirty = reaper.IsProjectDirty(T), sc = reaper.GetProjectStateChangeCount(T), vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") }
      end
      local frames = 0
      local t0 = reaper.time_precise()
      local plan = {
        { 0.0, function() reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 0.5) end }, -- the pending change
        { 0.2, function() probe("pending change, engine off") end },
        { 0.3, function() reaper.Main_OnCommand(ctx.cmd, 0) end },
        { 2.0, function() probe("engine running, stopped") end },
        { 2.1, function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(T) end },
        { SECONDS / 2, function() probe("engine running, playing"); R.frame_playing = reaper.GetExtState(EL.SECTION, "frame") end },
        { SECONDS / 2 + 0.05, function() R.play_at_half = reaper.GetPlayStateEx(T) end },
        { SECONDS / 2 + 0.1, function() reaper.OnStopButtonEx(T) end },
        { SECONDS - 0.5, function() probe("engine running, stopped again"); R.frame_end = reaper.GetExtState(EL.SECTION, "frame")
                                       R.sections = reaper.GetExtState(EL.SECTION, "sections") end },
        { SECONDS, function() reaper.Main_OnCommand(ctx.cmd, 0) end },  -- the action again: stop
        { SECONDS + 1.0, function() probe("engine stopped"); R.frame_stop = reaper.GetExtState(EL.SECTION, "frame"); R.done = true end },
      }
      -- Every move of the state counter is logged with its time, so a failure says when and in
      -- which phase it happened (one 600 s run on 2026-10-11 saw a single unexplained +1 while
      -- playing, and three runs since did not).
      local i = 1
      R.changes = {}
      local last_sc = reaper.GetProjectStateChangeCount(T)
      local function watch(t, why)
        local sc = reaper.GetProjectStateChangeCount(T)
        if sc ~= last_sc then
          R.changes[#R.changes + 1] = ("t=%.2f %d->%d %s, play=%d, this tab active=%s"):format(t, last_sc, sc, why,
            reaper.GetPlayStateEx(T), tostring(reaper.EnumProjects(-1) == T))
          last_sc = sc
        end
      end
      local function run()
        local t = reaper.time_precise() - t0
        watch(t, "between plan steps")
        if t - (R.seen or -9) >= 1 then -- a page looking (step 9b): the engine works sections out
          R.seen = t
          reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
        end
        while plan[i] and t >= plan[i][1] do plan[i][2](); watch(t, "right after plan step " .. i); i = i + 1 end
        if plan[i] then reaper.defer(run) end
      end
      reaper.defer(run)
      return nil, ("scenario of %d s scheduled"):format(SECONDS), SECONDS + 3
    end,
    function(tab, ctx)
      local R = _G.RFV_RO or {}
      _G.RFV_RO = nil
      EL.unregister(ctx.path)
      if not R.done then return false, "scenario did not finish" end
      local p0, lines, same = R.probes[1], {}, true
      for _, p in ipairs(R.probes) do
        lines[#lines + 1] = ("%-32s undo=%s redo=%s dirty=%d statecount=%d vol=%.2f"):format(p.label, p.undo, p.redo, p.dirty, p.sc, p.vol)
        if p.undo ~= p0.undo or p.redo ~= p0.redo or p.dirty ~= p0.dirty or p.sc ~= p0.sc then same = false end
      end
      local J = EL.json
      local fp, fe, fs = J.decode(R.frame_playing or ""), J.decode(R.frame_end or ""), J.decode(R.frame_stop or "")
      local sine = fp and fp.a and fp.a[1]
      local heard = fp and fp.play == 1 and type(sine) == "table" and sine[2] > -40
      lines[#lines + 1] = ("while playing: play=%s, Sine Z=%s dB; after %.0f s: %d frames, cost %s"):format(
        fp and fp.play or "?", type(sine) == "table" and sine[2] or "?", fe and fe.up or 0, fe and fe.seq or 0, fe and J.encode(fe.cost) or "?")
      lines[#lines + 1] = ("stopped frame: state %s (%s)"):format(fs and fs.state or "?", fs and fs.reason or "?")
      -- step 7: the spectrum map read the files all along, and Y came out
      local ym = fe and fe.ym
      local yv = fp and fp.y and fp.y[1]
      local spectra = type(ym) == "table" and ym.windows > 0 and type(yv) == "table" and yv[1] ~= J.null
      lines[#lines + 1] = ("spectra: %s windows read, the whole song %s read, Sine's Y while playing %s Hz%s"):format(
        type(ym) == "table" and ym.windows or "?", type(ym) == "table" and ym.song or "?", type(yv) == "table" and tostring(yv[1]) or "?",
        spectra and "" or "  <-- FAIL (the map did not run)")
      -- step 9b: both sections worked out while the page looked
      local sx = J.decode(R.sections or "")
      local worked = 0
      for _, x in ipairs(sx and sx.list or {}) do if x.played ~= nil and x.o then worked = worked + 1 end end
      local secs = worked == 2
      lines[#lines + 1] = ("sections: %d of 2 worked out (%s)%s"):format(worked, R.sections and R.sections:sub(1, 90) or "none",
        secs and "" or "  <-- FAIL")
      lines[#lines + 1] = "state counter moves (the first is the test's own pending change): " .. table.concat(R.changes or {}, " | ")
      return same and heard and spectra and secs and fs and fs.state == "stopped", table.concat(lines, "\n")
    end,
  },
}
