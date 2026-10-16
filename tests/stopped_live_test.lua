-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 9a, live: the stage when stopped, on the band fixture (whole mix shown, master muted),
-- against its rendered truth.
--   A. Never played since the engine started: the edit cursor stepped through the song in 2 s
--      steps (each step the next Y_SPAN seconds); every track's own level and X per section from
--      the frames, against the truth. Tracks with FX are off by what their FX add (reported).
--   B. The song played once through: the engine learns each FX gain.
--   C. The same steps again. Gate: own Z within 1.5 dB median per section, X within 1 degree.
--   Also: the engine follows each cursor move within one frame (the first frame at the new place
--   carries it); a fader moved while stopped shows in the next frame; a tone made by an FX while
--   stopped is no part, and an armed, monitored input still is.
--   Step 9a review F1: stopped at a place that played, each track as its meter measured it there
--   (against the frame that played those seconds); a track whose items change forgets that.
--   Step 9a review: where playing started and stopped (the edit cursor goes back there), every
--   part reads as measured there; what was learned comes back after the project is opened again
--   and the engine restarts (its file in REAPER's resource folder, removed afterwards; opened
--   again since the step 9b acceptance: new source objects, as after REAPER restarts); a track's
--   FX switched off while
--   stopped makes its level exact, switched on again "FX not heard".
-- python tools/rfv_test.py tests/stopped_live_test.lua --timeout 400

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(ENG .. "rfv_store.lua")
local V = dofile(ENG .. "rfv_view.lua")
local HD = dofile(ENG .. "rfv_heard.lua")
local EN = dofile(ENG .. "rfv_engine.lua") -- for the learning file's name only
local J = EL.json
local DIR = L.env().truth .. SEP .. "band" .. SEP

local SECTIONS = { { "Verse 2", 2, 30 }, { "Backing vocals", 30, 60 }, { "Shaker", 60, 78 }, { "Ending", 78, 96 } }
local STEPS = {}
for t = 2, 94, 2 do STEPS[#STEPS + 1] = t end

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return J.decode(s)
end

local function stats(v)
  local s = {}
  for i, x in ipairs(v) do s[i] = math.abs(x) end
  table.sort(s)
  if #s == 0 then return 0, 0, 0 end
  local med = #s % 2 == 1 and s[(#s + 1) // 2] or (s[#s // 2] + s[#s // 2 + 1]) / 2
  return med, s[math.max(1, math.floor(#s * 0.9 + 0.5))], s[#s]
end

-- Step the edit cursor through STEPS; for each, the first frame computed at the new place.
local function sweep(ctx, key)
  local i, t_set, rec, lats = 1, nil, {}, {}
  local function go()
    if ctx.stop then return end
    if not t_set then
      if i > #STEPS then ctx[key], ctx[key .. "_lat"] = rec, lats; return end
      reaper.SetEditCurPos2(ctx.tab, STEPS[i], false, false)
      t_set = reaper.time_precise()
    else
      local f = EL.read("frame")
      if f and f.sm == 1 and math.abs(f.pos - STEPS[i]) < 1e-3 and f.t >= t_set then
        rec[STEPS[i]] = { a = f.a, ob = f.ob, ma = f.ma }
        lats[#lats + 1] = reaper.time_precise() - t_set
        i, t_set = i + 1, nil
      elseif reaper.time_precise() - t_set > 3 then
        ctx[key .. "_err"] = ("no frame at %.1f s within 3 s"):format(STEPS[i]); return
      end
    end
    reaper.defer(go)
  end
  reaper.defer(go)
end

-- Per section and track: the level of the mean power over the steps in it (null = silent), and
-- X from those powers, against the truth's own; tracks the truth hears above -50 dB.
local function judge(ctx, rec)
  local ez, ex, fx_e, nofx_e = {}, {}, {}, {}
  local worst, nolevel = {}, {}
  for _, sec in ipairs(SECTIONS) do
    for i, tt in ipairs(ctx.truth.tracks) do
      local t = tt.own[sec[1]]
      if t and t.level_db and t.level_db > -50 then
        local pl, pr, n = 0, 0, 0
        for _, s in ipairs(STEPS) do
          if s >= sec[2] and s + 2 <= sec[3] then
            n = n + 1
            local a = rec[s] and rec[s].a and rec[s].a[i]
            if a and a ~= J.null and a[2] ~= J.null then
              local l, r = HD.powers(a[1] ~= J.null and a[1] or nil, a[2])
              pl, pr = pl + l, pr + r
            end
          end
        end
        if n > 0 and pl + pr <= 0 then
          -- no level anywhere in the section: a part the model has nothing for (a virtual
          -- instrument never heard: decision 3, no level guessed)
          nolevel[#nolevel + 1] = ("%s / %s"):format(tt.name, sec[1])
        elseif n > 0 then
          pl, pr = pl / n, pr / n
          local z = 10 * math.log(pl + pr, 10)
          local e = z - t.level_db
          ez[#ez + 1] = e
          local fx = ctx.fx[i]
          if fx then fx_e[#fx_e + 1] = e else nofx_e[#nofx_e + 1] = e end
          local x = HD.azimuth(pl, pr)
          if x and t.az_deg then ex[#ex + 1] = x - t.az_deg end
          worst[#worst + 1] = { math.abs(e), ("%s / %s: %+.2f dB%s"):format(tt.name, sec[1], e, fx and " (FX)" or "") }
        end
      end
    end
  end
  table.sort(worst, function(a, b) return a[1] > b[1] end)
  return ez, ex, fx_e, nofx_e, worst, nolevel
end

local function report(ctx, rec, label)
  local ez, ex, fx_e, nofx_e, worst, nolevel = judge(ctx, rec)
  local zm, zp, zx = stats(ez)
  local xm, xp, xx = stats(ex)
  local fm, fp = stats(fx_e)
  local nm, np = stats(nofx_e)
  local lines = { ("%s: Z median %.2f dB, p90 %.2f, max %.2f (n=%d); without FX %.2f / %.2f (n=%d), with FX %.2f / %.2f (n=%d); X median %.2f deg, p90 %.2f, max %.2f"):format(
    label, zm, zp, zx, #ez, nm, np, #nofx_e, fm, fp, #fx_e, xm, xp, xx) }
  for i = 1, math.min(4, #worst) do lines[#lines + 1] = "    " .. worst[i][2] end
  lines[#lines + 1] = ("    no level (nothing to go on): %s"):format(#nolevel > 0 and table.concat(nolevel, ", ") or "none")
  return zm, xm, table.concat(lines, "\n"), #nolevel
end

local function object_of(name)
  local g = EL.read("graph")
  for j, o in ipairs(g and g.stage.objects or {}) do
    if o.track ~= J.null and g.tracks[o.track + 1].name == name then return j end
  end
end

-- every object drawn whose level rests on FX measured here (at least 90 %); the others listed
local function all_here(f)
  local g = EL.read("graph")
  local low, n = {}, 0
  for j, b in ipairs(f.ob or {}) do
    if b ~= J.null then
      n = n + 1
      if b[1] < 0.9 then low[#low + 1] = ("%s %.2f"):format(g.tracks[g.stage.objects[j].track + 1].name, b[1]) end
    end
  end
  return #low == 0 and n > 0, ("%d objects drawn%s"):format(n, #low > 0 and (", not measured here: " .. table.concat(low, ", ")) or ", every one measured here")
end

return {
  name = "stopped-live",
  cleanup = function(ctx)
    ctx.stop = true
    EL.stop()
    if ctx.epath then EL.unregister(ctx.epath) end
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
    if ctx.learnfile then os.remove(ctx.learnfile); os.remove(ctx.learnfile .. ".tmp") end
  end,
  steps = {
    function(tab, ctx)
      ctx.truth = read_json(DIR .. "truth.json")
      local st = read_json(DIR .. "structure.json")
      if not ctx.truth or not st then return false, "no truth for band (tools: truth_export.lua)" end
      ctx.fx = {}
      for i, t in ipairs(st.tracks) do ctx.fx[i] = (t.fx or 0) > 0 end
      local rpp = DIR .. "band.rpp"
      ctx.side = S.sidecar_path(rpp)
      reaper.Main_openProject("noprompt:" .. rpp)
      ctx.tab = reaper.EnumProjects(-1)
      -- nothing learned before: an earlier run's file would make "never played" learned
      local _, lf = EN.learn_file(ctx.tab, EL.SECTION)
      ctx.learnfile = lf
      if lf then os.remove(lf) end
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(ctx.tab), "B_MUTE", 1)
      reaper.GetSetRepeatEx(ctx.tab, 0)
      S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end)
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_stopped")
      EL.run_later(ctx.ecmd)
      reaper.SetEditCurPos2(ctx.tab, 0, false, false)
      return nil, "band open, engine started, stopped; the map's coarse pass under way", 45
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local ym = f and f.ym
      ctx.coarse0 = ym and ym ~= J.null and ym.coarse or -1
      sweep(ctx, "A")
      return nil, ("coarse pass %.2f, dense %.2f; stepping the cursor (never played)"):format(ctx.coarse0, ym and ym ~= J.null and ym.song or -1), 20
    end,
    function(tab, ctx)
      if ctx.A_err then return false, ctx.A_err end
      if not ctx.A then return false, "the first sweep did not finish" end
      local _, _, line = report(ctx, ctx.A, "A, never played")
      ctx.lineA = line
      local P = ctx.tab
      reaper.SetEditCurPos2(P, 50, false, false)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(P) end)
      return nil, line .. "\nplaying 6 s from 50 s", 6.5
    end,
    function(tab, ctx)
      reaper.OnStopButtonEx(ctx.tab)
      return nil, ("stopped; the edit cursor at %.2f"):format(reaper.GetCursorPositionEx(ctx.tab)), 0.8
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      ctx.startok, ctx.startline = all_here(f)
      ctx.startline = ("where playing started (%.2f s): %s"):format(f.pos, ctx.startline)
      local P = ctx.tab
      reaper.SetEditCurPos2(P, 0, false, false)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(P) end)
      -- the frames whose meters cover each step's 2 s (played at the step + 2 s)
      ctx.heard_at = {}
      local function rec()
        if ctx.stop or ctx.played then return end
        local f = EL.read("frame")
        if f and f.play & 1 == 1 then
          for _, st in ipairs(STEPS) do
            local d = math.abs(f.pos - (st + 2))
            if d <= 0.1 and (not ctx.heard_at[st] or d < ctx.heard_at[st].d) then ctx.heard_at[st] = { d = d, a = f.a } end
          end
        end
        reaper.defer(rec)
      end
      reaper.defer(rec)
      return nil, ctx.startline .. "\nplaying the song once through", 97.5
    end,
    function(tab, ctx)
      reaper.OnStopButtonEx(ctx.tab)
      ctx.played = true
      local f = EL.read("frame")
      ctx.learned = f and f.ym ~= J.null and f.ym.learned or -1
      ctx.saveinfo = function()
        local g = EL.read("frame")
        local ym = g and g.ym ~= J.null and g.ym
        return ym and ("written when playing stopped: %.0f KB in %.1f ms"):format(ym.save_kb or -1, ym.save_ms or -1) or "?"
      end
      sweep(ctx, "C")
      return nil, ("stopped; %d blocks learned; stepping the cursor again"):format(ctx.learned), 20
    end,
    function(tab, ctx)
      if ctx.C_err then return false, ctx.C_err end
      if not ctx.C then return false, "the second sweep did not finish" end
      local zm, xm, line, nolevel = report(ctx, ctx.C, "C, after one play")
      ctx.zm, ctx.xm, ctx.lineC, ctx.nolevelC = zm, xm, line, nolevel
      local lats = {}
      for _, v in ipairs(ctx.A_lat) do lats[#lats + 1] = v end
      for _, v in ipairs(ctx.C_lat) do lats[#lats + 1] = v end
      ctx.lat_med, ctx.lat_p90, ctx.lat_max = stats(lats)
      -- the F1 measure: each track stopped at a step against its meter over the same seconds
      local d = {}
      for _, st in ipairs(STEPS) do
        local h, m = ctx.heard_at[st], ctx.C[st]
        if h and m then
          for i, a in ipairs(m.a) do
            local b = h.a[i]
            if a ~= J.null and b ~= J.null and a[2] ~= J.null and b[2] ~= J.null and b[2] > -60 then d[#d + 1] = a[2] - b[2] end
          end
        end
      end
      ctx.cm, ctx.cp, ctx.cx = stats(d)
      ctx.cline = ("stopped where it played, against the meters over the same 2 s: median %.2f dB, p90 %.2f, max %.2f (n=%d); the learning %s"):format(ctx.cm, ctx.cp, ctx.cx, #d, ctx.saveinfo())
      EL.stop()
      return nil, line .. "\n" .. ctx.cline .. "\nthe engine stopped", 1.5
    end,
    function(tab, ctx)
      local f = ctx.learnfile and io.open(ctx.learnfile, "rb")
      ctx.filebytes = f and #f:read("a") or 0
      if f then f:close() end
      -- the project opened again first, as after a restart of REAPER: every take gets a new
      -- source object (step 9b acceptance: a fingerprint holding the source's pointer then
      -- forgot what the meters measured)
      reaper.Main_openProject("noprompt:" .. DIR .. "band.rpp")
      ctx.tab = reaper.EnumProjects(-1)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(ctx.tab), "B_MUTE", 1)
      reaper.GetSetRepeatEx(ctx.tab, 0)
      EL.reset()
      EL.run_later(ctx.ecmd)
      reaper.SetEditCurPos2(ctx.tab, 12, false, false)
      return nil, ("the learning file: %d bytes; the project opened again, a new engine started"):format(ctx.filebytes), 5
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      ctx.restartok, ctx.restartline = all_here(f)
      ctx.restartline = ("after a restart, at %.2f s (%s blocks learned): %s"):format(f.pos, f.ym ~= J.null and tostring(f.ym.learned) or "?", ctx.restartline)
      -- the media set offline and online again, as REAPER does going to the background and back
      -- ("offlineinact"): nothing learned is forgotten, nothing read again (step 10b)
      ctx.resets0 = f.ym ~= J.null and f.ym.resets or -1
      reaper.Main_OnCommand(40100, 0)
      reaper.Main_OnCommand(40101, 0)
      return nil, ctx.restartline .. "; media set offline and online", 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local ok, line = all_here(f)
      local resets = f.ym ~= J.null and f.ym.resets or -1
      ctx.offok = ok and resets == ctx.resets0
      ctx.offline = ("media offline and online again: %s; the map's drops %d -> %d"):format(line, ctx.resets0, resets)
      -- Gtr 1's FX switched off while stopped
      ctx.gj = object_of("Gtr 1")
      for i = 0, reaper.CountTracks(ctx.tab) - 1 do
        local tr = reaper.GetTrack(ctx.tab, i)
        local _, nm = reaper.GetTrackName(tr)
        if nm == "Gtr 1" then ctx.gtr, ctx.gi = tr, i + 1 end
      end
      for fx = 0, reaper.TrackFX_GetCount(ctx.gtr) - 1 do reaper.TrackFX_SetEnabled(ctx.gtr, fx, false) end
      return nil, ctx.offline, 0.8
    end,
    function(tab, ctx)
      local b = EL.read("frame").ob[ctx.gj]
      ctx.off = b ~= J.null and b or nil
      for fx = 0, reaper.TrackFX_GetCount(ctx.gtr) - 1 do reaper.TrackFX_SetEnabled(ctx.gtr, fx, true) end
      return nil, nil, 0.8
    end,
    function(tab, ctx)
      local b = EL.read("frame").ob[ctx.gj]
      ctx.on = b ~= J.null and b or nil
      local v = function(x) return x and ("[%.2f, %.2f, %.2f]"):format(x[1], x[2], x[3]) or "null" end
      ctx.fxok = ctx.off and ctx.off[1] >= 0.99 and ctx.on and ctx.on[3] >= 0.99
      ctx.fxline = ("Gtr 1's FX switched off while stopped: %s (exact); on again: %s (not heard): %s"):format(v(ctx.off), v(ctx.on), ctx.fxok and "ok" or "<-- FAIL")
      -- Gtr 2 at 12 s before and after its items are muted
      ctx.g2 = object_of("Gtr 2")
      reaper.SetEditCurPos2(ctx.tab, 12, false, false)
      return nil, ctx.fxline, 0.6
    end,
    function(tab, ctx)
      local o = EL.read("frame").o[ctx.g2]
      ctx.g2_before = o ~= J.null and o[2] ~= J.null and o[2] or nil
      for i = 0, reaper.CountTracks(ctx.tab) - 1 do
        local tr = reaper.GetTrack(ctx.tab, i)
        local _, nm = reaper.GetTrackName(tr)
        if nm == "Gtr 2" then
          for it = 0, reaper.CountTrackMediaItems(tr) - 1 do reaper.SetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, it), "B_MUTE", 1) end
        end
      end
      return nil, nil, 1.5
    end,
    function(tab, ctx)
      -- without items Gtr 2 may leave the stage (the routing's roles change): find it again
      local j = object_of("Gtr 2")
      local o = j and EL.read("frame").o[j]
      ctx.g2_after = o and o ~= J.null and o[2] ~= J.null and o[2] or nil
      ctx.itemok = ctx.g2_before ~= nil and ctx.g2_after == nil
      ctx.itemline = ("Gtr 2's items muted while stopped: %s -> %s: %s"):format(tostring(ctx.g2_before), tostring(ctx.g2_after),
        ctx.itemok and "the level it was measured at is forgotten, not drawn (ok)" or "<-- FAIL")
      -- a fader moved while stopped: Gtr 1 down 6.02 dB at 40 s
      reaper.SetEditCurPos2(ctx.tab, 40, false, false)
      ctx.gtr = nil
      for i = 0, reaper.CountTracks(ctx.tab) - 1 do
        local tr = reaper.GetTrack(ctx.tab, i)
        local _, nm = reaper.GetTrackName(tr)
        if nm == "Gtr 1" then ctx.gtr, ctx.gi = tr, i + 1 end
      end
      -- the files around 40 s read in full first (after the restart the map starts again), so only
      -- the fader moves the level between the two frames
      return nil, ctx.fxline, 6
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local a = f and f.a[ctx.gi]
      ctx.z0 = a and a ~= J.null and a[2] or nil
      reaper.SetMediaTrackInfo_Value(ctx.gtr, "D_VOL", reaper.GetMediaTrackInfo_Value(ctx.gtr, "D_VOL") * 0.5)
      ctx.t_fader = reaper.time_precise()
      local function go() -- the first frame after the move
        if ctx.stop then return end
        local g = EL.read("frame")
        if g and g.t > ctx.t_fader then
          local b = g.a[ctx.gi]
          ctx.z1, ctx.fader_lat = b and b ~= J.null and b[2] or nil, reaper.time_precise() - ctx.t_fader
          return
        end
        reaper.defer(go)
      end
      reaper.defer(go)
      return nil, nil, 0.6
    end,
    function(tab, ctx)
      ctx.fader_ok = ctx.z0 and ctx.z1 and math.abs((ctx.z1 - ctx.z0) + 6.02) < 0.1
      -- noise while stopped: a tone from an FX on a track that is not armed; and an armed,
      -- monitored track on input 1 (its noise floor)
      local n = reaper.CountTracks(tab)
      ctx.tone = L.track(tab, "Tone", 0)
      local fx = reaper.TrackFX_AddByName(ctx.tone, "JS: Tone Generator", false, -1)
      if fx >= 0 then
        reaper.TrackFX_SetParam(ctx.tone, fx, 0, -40) -- wet
        reaper.TrackFX_SetParam(ctx.tone, fx, 1, -120) -- dry
      end
      ctx.live = L.track(tab, "Live", 0)
      reaper.SetMediaTrackInfo_Value(ctx.live, "I_RECINPUT", 0)
      reaper.SetMediaTrackInfo_Value(ctx.live, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(ctx.live, "I_RECARM", 1)
      ctx.ti, ctx.li = n + 1, n + 2
      reaper.defer(function() reaper.Main_OnCommand(40101, 0) end)
      return nil, ("tone FX %s; audio %s"):format(fx >= 0 and "added" or "MISSING", tostring(reaper.Audio_IsRunning())), 3
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local running = reaper.Audio_IsRunning() == 1
      local tone_meter = math.max(reaper.Track_GetPeakInfo(ctx.tone, 0), reaper.Track_GetPeakInfo(ctx.tone, 1))
      local live_meter = math.max(reaper.Track_GetPeakInfo(ctx.live, 0), reaper.Track_GetPeakInfo(ctx.live, 1))
      local at, al = f and f.a[ctx.ti], f and f.a[ctx.li]
      local tone_off = at == nil or at == J.null
      local live_on = al ~= nil and al ~= J.null
      for i = 0, reaper.CountTracks(tab) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(tab, i), "I_RECARM", 0) end
      EL.stop()
      local ok = ctx.zm <= 1.5 and ctx.xm <= 1.0 and ctx.nolevelC == 0 and ctx.lat_p90 <= 0.15 and ctx.fader_ok and tone_off and (live_on or live_meter < 1e-5)
        and ctx.startok and ctx.restartok and ctx.offok and ctx.filebytes > 0 and ctx.fxok and ctx.itemok and ctx.cm <= 1.0
      return ok, table.concat({
        ctx.cline .. (ctx.cm <= 1.0 and "" or "   <-- FAIL (<= 1.0)"),
        ctx.itemline,
        ctx.startline .. (ctx.startok and "" or "   <-- FAIL"),
        ("the learning file: %d bytes; %s%s"):format(ctx.filebytes, ctx.restartline, ctx.restartok and "" or "   <-- FAIL"),
        ctx.offline .. (ctx.offok and "" or "   <-- FAIL"),
        ctx.fxline,
        ("gate: Z median %.2f dB (<= 1.5), X median %.2f deg (<= 1), parts with no level after one play: %d (0)"):format(ctx.zm, ctx.xm, ctx.nolevelC),
        ("cursor moves: the first frame at the new place %.3f s median, p90 %.3f, max %.3f (<= 0.15 at p90; %d moves)"):format(ctx.lat_med, ctx.lat_p90, ctx.lat_max, #ctx.A_lat + #ctx.C_lat),
        ("fader -6.02 dB while stopped: own Z %s -> %s in %.3f s: %s"):format(tostring(ctx.z0), tostring(ctx.z1), ctx.fader_lat or -1, ctx.fader_ok and "ok" or "<-- FAIL"),
        ("while stopped, audio %s: a tone from an FX, meter %.1f dB: %s; an armed, monitored input, meter %.1f dB: %s"):format(
          running and "running" or "closed", 20 * math.log(math.max(tone_meter, 1e-9), 10), tone_off and "not a part (ok)" or "taken for a part <-- FAIL",
          20 * math.log(math.max(live_meter, 1e-9), 10), live_on and "shown (ok)" or (live_meter < 1e-5 and "silent input, not shown" or "not shown <-- FAIL")),
      }, "\n")
    end,
  },
}
