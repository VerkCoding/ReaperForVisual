-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 4.3: roles inside the running engine, on the styles fixture.
--   * the graph carries every track's role, group, path, flags and reason;
--   * nothing is classified again while nothing changes;
--   * the meter safety net: the JS Tone Generator, invisible to TrackFX_GetInstrument, sounds
--     even while stopped, is heard within ~0.5 s and becomes a source ("unexplained"); tracks
--     that really are silent (offline, bypassed, no instrument) stay ignored while playing;
--   * the user's overrides in .rfv.json (a layer, an ignore, a chosen main path) are applied;
--   * a change that makes no undo point (arming a track) is picked up within ~2 s;
--   * step 10a: the tone switched off while playing is let go after 30 s without a sound.
-- The master and the hardware-output track are at -inf, so nothing reaches the speakers.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local S = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_store.lua")

local function by_name(g)
  local t = {}
  for _, x in ipairs(g and g.tracks or {}) do t[x.name] = x end
  return t
end
local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end
local function track(tab, name)
  for i = 0, reaper.CountTracks(tab) - 1 do
    local tr = reaper.GetTrack(tab, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
end

return {
  name = "engine-roles",
  steps = {
    function(tab, ctx)
      dofile(HERE .. "fixtures" .. SEP .. "styles.lua")(tab)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "D_VOL", 0)
      reaper.SetMediaTrackInfo_Value(track(tab, "Click to phones"), "D_VOL", 0) -- its hardware output too
      ctx.tab = L.save_reopen(tab, H.tmpdir("engine-roles") .. SEP .. "styles.rpp")
      os.remove(H.tmpdir("engine-roles") .. SEP .. "styles.rfv.json")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_roles")
      EL.run_later(ctx.cmd)
      return nil, "styles built, engine started", 2.0
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local t = by_name(g)
      local n = 0
      for _, x in ipairs(g and g.tracks or {}) do if x.role then n = n + 1 end end
      ctx.c1 = g and g.roles and g.roles.classified
      local ok = g and n == #g.tracks and t.Kick.role == "source" and t.Kick.group == t.Drums.i and t.Verb.role == "return"
        and has(t["Gtr L"].flags, "tie") and t["Gtr L"].dry == t["Gtr bus"].i
        and t["Tone JS"].role == "source" and t["Tone JS"].kind == "unexplained" and g.roles.heard == 1
        and t["Harmony"].group == t["Vox bus"].i and #t["Harmony"].path == 3
      return ok, ("graph %d bytes: %d/%d tracks with roles; Kick %s in %s; Tone JS %s/%s (heard %s); classified %s times, classify %.2f ms, snapshot %.2f ms"):format(
        #reaper.GetExtState(EL.SECTION, "graph"), n, g and #g.tracks or 0, t.Kick and t.Kick.role, t.Kick and g.tracks[(t.Kick.group or -1) + 1].name,
        t["Tone JS"] and t["Tone JS"].role, t["Tone JS"] and t["Tone JS"].kind, tostring(g.roles.heard), tostring(ctx.c1),
        g.roles.classify_ms, g.roles.snapshot_ms), 5.0
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local same = g.roles.classified == ctx.c1
      reaper.SetEditCurPos2(tab, 0, false, false)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(ctx.tab) end)
      return same, ("after 5 s with no change: classified %d times (was %d); playing"):format(g.roles.classified, ctx.c1), 3.0
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local t = by_name(g)
      reaper.OnStopButtonEx(tab)
      local js = t["Tone JS"]
      local ok = js.role == "source" and has(js.flags, "unexplained") and g.roles.heard == 1 and g.roles.classified == ctx.c1
        and t["Pad offline"].role == "ignored" and t["Pad bypassed"].role == "ignored" and t["Synth chain off"].role == "ignored"
        and t["MIDI only"].role == "ignored" and t.Empty.role == "ignored"
      -- the user's overrides, written the way every RFV writer does
      local st = {}
      S.follow(tab, st)
      local gbus, gpar, gl, verb = t["Gtr bus"].guid, t["Gtr par"].guid, t["Gtr L"].guid, t.Verb.guid
      local wrote, err = S.edit(tab, st, function(doc)
        doc.roles[gpar] = "layer:" .. gbus
        doc.roles[verb] = "ignore"
        doc.paths = EL.json.object{ [gl] = gpar }
      end)
      return ok and wrote, ("after 3 s of playback: heard %d, classified %d times; offline, bypassed and chain-off synths and MIDI only stay ignored: %s; overrides written: %s"):format(
        g.roles.heard, g.roles.classified, tostring(t["Pad offline"].role == "ignored" and t["Pad bypassed"].role == "ignored"
          and t["Synth chain off"].role == "ignored" and t["MIDI only"].role == "ignored"),
        tostring(wrote) .. (err and (" " .. tostring(err.msg)) or "")), 2.5
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local t = by_name(g)
      local par, gl, verb = t["Gtr par"], t["Gtr L"], t.Verb
      local ok = par.role == "layer" and par.layer_of == t["Gtr bus"].i and par.group == t["Gtr bus"].i
        and verb.role == "ignored" and verb.kind == "user" and gl.dry == par.i and has(gl.flags, "user") and not has(gl.flags, "tie")
        and has(t["Gtr R"].flags, "tie")
      -- a change with no undo point: arm "Empty" with input monitoring (the master is at -inf)
      local e = track(tab, "Empty")
      reaper.SetMediaTrackInfo_Value(e, "I_RECINPUT", 0)
      reaper.SetMediaTrackInfo_Value(e, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(e, "I_RECARM", 1)
      ctx.armed_at = reaper.time_precise()
      return ok, ("overrides: Gtr par %s of %s; Verb %s/%s; Gtr L main path %s, flags %s; then Empty armed"):format(
        par.role, tostring(par.layer_of and g.tracks[par.layer_of + 1].name), verb.role, verb.kind,
        tostring(gl.dry and g.tracks[gl.dry + 1].name), table.concat(gl.flags, ",")), 3.0
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local t = by_name(g)
      local ok = t.Empty.role == "source" and t.Empty.kind == "live"
      reaper.SetMediaTrackInfo_Value(track(tab, "Empty"), "I_RECARM", 0)
      -- step 10a: the tone switched off while playing; silent for 30 s of playing, it is let go
      local js = track(tab, "Tone JS")
      for fx = 0, reaper.TrackFX_GetCount(js) - 1 do reaper.TrackFX_SetEnabled(js, fx, false) end
      -- the song is 10 s: played in a loop, so the 30 s are played ones
      reaper.GetSet_LoopTimeRange2(ctx.tab, true, true, 0, 10, false)
      reaper.GetSetRepeatEx(ctx.tab, 1)
      reaper.SetEditCurPos2(tab, 0, false, false)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(ctx.tab) end)
      return ok, ("armed Empty is now %s/%s (looked at within %.1f s); classified %d times in all; Tone JS switched off, playing"):format(
        t.Empty.role, t.Empty.kind, reaper.time_precise() - ctx.armed_at, g.roles.classified), 32.5
    end,
    function(tab, ctx)
      local g = EL.read("graph")
      local t = by_name(g)
      reaper.OnStopButtonEx(tab)
      EL.stop()
      local js = t["Tone JS"]
      local ok = js.role == "ignored" and g.roles.heard == 0
      return ok, ("Tone JS silent for 30 s of playing: %s/%s, heard by the safety net %d (let go)"):format(js.role, tostring(js.kind), g.roles.heard), 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
