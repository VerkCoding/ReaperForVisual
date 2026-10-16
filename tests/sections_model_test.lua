-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 9b review, live: a section's average stage on numbers known by arithmetic, and where
-- sections come from. A project of 30 s, no FX, master muted: "Sine" a sine from 0 to 10 s and
-- the same 10 dB lower from 10 to 20 s; "Gap" the sine from 0 to 5 s only; "Whole" noise all
-- along, its volume automated in steps (0 dB, -20 dB from 10 s, 0 dB from 20 s: step 10b);
-- regions "R" (0-20 s), "Tail" (20-30 s) and ten 2 s regions "P1".."P10" over R (twelve
-- sections, so the one a page shows has to go first); markers "#A" (0), "cue" (12), "#B" (20),
-- "x" (25), "y" (26), "end" (29.8). Levels against the stage at the cursor at 2 s (from the files,
-- exact there). Noise is not judged against its meter: REAPER's meters read peaks, and the crest
-- correction fitted on the band's instruments puts white noise 6 dB over its files (measured).
--   1. Never played: in R, Sine 2.60 dB under its loud half (the mean of 1 and 0.1) and Gap 6.02
--      dB under where it plays (a quarter of R: silence counts); Whole 2.97 dB under the cursor (its
--      automation averaged over R, not read at its middle); in Tail,
--      Sine and Gap not there; nothing measured; each section's files read through ("read" 1).
--   2. Played from 12 to 20 s only (the quiet half): R's Sine still 2.60 dB under its loud half,
--      within 0.75 dB (the blocks that played as the meters measured them, the files for the
--      others; the files over the whole section put it 2 dB lower: step 9b review); Gap, never
--      heard there, 6.02 dB under; R partly measured.
--   3. A fader moved while stopped: how soon Tail's stage shows it, with no section on a page and
--      with Tail on the page ("page_sect").
--   4. Where sections come from, as the page sets it: "# markers" (A 0-20, B 20-30), "every
--      marker" (#A 0-12, cue 12-20, #B 20-25, y 26-30: x makes a section under 2 s, "end" stands
--      at the song's end), regions again. A in "# markers" is R again.
-- python tools/rfv_test.py tests/sections_model_test.lua --timeout 300

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(ENG .. "rfv_store.lua")
local V = dofile(ENG .. "rfv_view.lua")
local EN = dofile(ENG .. "rfv_engine.lua") -- for the learning file's name only
local J = EL.json

local function object_of(name)
  local g = EL.read("graph")
  for j, o in ipairs(g and g.stage.objects or {}) do
    if o.track ~= J.null and g.tracks[o.track + 1].name == name then return j end
  end
end

local function section(name)
  local s = EL.read("sections")
  for _, x in ipairs(s and s.list or {}) do if x.name == name then return x end end
end

-- an object's Z in a section (nil: not worked out yet, or not there)
local function z_in(sec, name)
  local j = object_of(name)
  local v = sec and sec.o and j and sec.o[j]
  return v and v ~= J.null and v[2] ~= J.null and v[2] or nil
end

local function names(s)
  local out = {}
  for _, x in ipairs(s and s.list or {}) do out[#out + 1] = ("%s %g-%g"):format(x.name, x.a, x.b) end
  return table.concat(out, ", ")
end

local function send(ctx, obj)
  ctx.seq = (ctx.seq or 7000) + 1
  obj.tab = EL.read("graph").tab
  local body = J.encode(J.object(obj))
  reaper.SetExtState(EL.SECTION, "cmd", ("%d|%d|%s"):format(ctx.seq, #body, body), false)
end

-- how long until Tail's stage shows Whole's fader moved (its Z past want, in the direction of dir)
local function watch_tail(ctx, key, want, dir)
  local t0 = reaper.time_precise()
  local function go()
    if ctx.stop then return end
    local z = z_in(section("Tail"), "Whole")
    if z and (z - want) * dir >= 0 then ctx[key] = reaper.time_precise() - t0; return end
    if reaper.time_precise() - t0 > 15 then ctx[key] = -1; return end
    reaper.defer(go)
  end
  reaper.defer(go)
end

return {
  name = "sections-model",
  cleanup = function(ctx)
    ctx.stop = true
    EL.stop()
    if ctx.epath then EL.unregister(ctx.epath) end
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
    if ctx.learnfile then os.remove(ctx.learnfile); os.remove(ctx.learnfile .. ".tmp") end
  end,
  steps = {
    function(tab, ctx)
      local sig = L.env().signals .. SEP
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      local sine = L.track(tab, "Sine", 0)
      L.item(sine, sig .. "sine1k_m12.wav", 0, 10)
      local quiet = L.item(sine, sig .. "sine1k_m12.wav", 10, 10, 10)
      reaper.SetMediaItemInfo_Value(quiet, "D_VOL", 10 ^ (-10 / 20))
      L.item(L.track(tab, "Gap", 0), sig .. "sine1k_m12.wav", 0, 5)
      ctx.whole = L.track(tab, "Whole", 0)
      L.item(ctx.whole, sig .. "noise_m20.wav", 0, 30)
      -- step 10b: Whole's volume automated in steps, 0 dB, -20 dB from 10 s, 0 dB again from 20 s:
      -- over R its stage is the mean of the two (-2.97 dB), not the value at R's middle (10 s)
      reaper.SetOnlyTrackSelected(ctx.whole)
      L.act(40406, "volume envelope")
      local ve = reaper.GetTrackEnvelopeByName(ctx.whole, "Volume")
      local mode = reaper.GetEnvelopeScalingMode(ve)
      reaper.DeleteEnvelopePointRange(ve, -1, 100)
      for _, pt in ipairs({ { 0, 1 }, { 10, 0.1 }, { 20, 1 } }) do
        reaper.InsertEnvelopePoint(ve, pt[1], reaper.ScaleToEnvelopeMode(mode, pt[2]), 1, 0, false, true) -- square
      end
      reaper.Envelope_SortPoints(ve)
      L.region(tab, "R", 0, 20)
      L.region(tab, "Tail", 20, 30)
      for i = 1, 10 do L.region(tab, "P" .. i, 2 * (i - 1), 2 * i) end
      for _, m in ipairs({ { 0, "#A" }, { 12, "cue" }, { 20, "#B" }, { 25, "x" }, { 26, "y" }, { 29.8, "end" } }) do
        reaper.AddProjectMarker2(tab, false, m[1], 0, m[2], -1, 0)
      end
      reaper.GetSetRepeatEx(tab, 0)
      local rpp = H.tmpdir("sectmodel") .. SEP .. "sectmodel.rpp"
      ctx.side = S.sidecar_path(rpp)
      for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, rpp)
      ctx.whole = reaper.GetTrack(ctx.tab, 2)
      local _, lf = EN.learn_file(ctx.tab, EL.SECTION)
      ctx.learnfile = lf
      if lf then os.remove(lf) end
      S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end)
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_sectmodel")
      EL.run_later(ctx.ecmd)
      reaper.SetEditCurPos2(ctx.tab, 2, false, false)
      -- a page looking all along; the lowest share of R's files read seen while they are read
      ctx.minread = 2
      local function seen()
        if ctx.stop then return end
        local t = reaper.time_precise()
        if not ctx.seen_t or t - ctx.seen_t >= 1 then
          ctx.seen_t = t
          reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
          if ctx.view then reaper.SetExtState(EL.SECTION, "page_sect", ("%d|%s"):format(os.time() * 1000, ctx.view), false) end
        end
        local r = section("R")
        if r and r.read then ctx.minread = math.min(ctx.minread, r.read) end
        reaper.defer(seen)
      end
      reaper.defer(seen)
      return nil, "30 s project: Sine (0-10 s, then 10 dB lower to 20 s), Gap (0-5 s), Whole (noise); 12 regions, 6 markers; engine started, stopped at 2 s", 15
    end,
    function(tab, ctx)
      local s, f = EL.read("sections"), EL.read("frame")
      ctx.list0 = names(s)
      -- the stage at the cursor (2 s: everything plays there, files only, exact)
      local function cz(name)
        local j = object_of(name)
        local v = f and f.sm == 1 and j and f.o[j]
        return v and v ~= J.null and v[2] ~= J.null and v[2] or nil
      end
      ctx.cs, ctx.cg, ctx.cw = cz("Sine"), cz("Gap"), cz("Whole")
      local r, tl = section("R"), section("Tail")
      ctx.r1s, ctx.r1g, ctx.r1w = z_in(r, "Sine"), z_in(r, "Gap"), z_in(r, "Whole")
      ctx.t1s, ctx.t1g, ctx.t1w = z_in(tl, "Sine"), z_in(tl, "Gap"), z_in(tl, "Whole")
      ctx.read1, ctx.played1 = r and r.read, r and r.played
      -- the share the meters measured at the cursor: none (no FX: exact from the files, not measured)
      ctx.mp1 = f and f.sm == 1 and f.mp
      ctx.ws, ctx.wg = ctx.cs and ctx.cs + 10 * math.log(0.55, 10), ctx.cg and ctx.cg - 10 * math.log(4, 10)
      ctx.ww = ctx.cw and ctx.cw + 10 * math.log(0.505, 10) -- Whole at 0 dB, then -20 dB, half each
      ctx.ok1 = ctx.cs and ctx.cg and ctx.cw and ctx.r1s and ctx.r1g and ctx.r1w and tl and tl.o and not ctx.t1s and not ctx.t1g and ctx.t1w
        and math.abs(ctx.r1s - ctx.ws) <= 0.2 and math.abs(ctx.r1g - ctx.wg) <= 0.2 and math.abs(ctx.r1w - ctx.ww) <= 0.3
        and math.abs(ctx.t1w - ctx.cw) <= 0.3 and ctx.read1 == 1 and ctx.played1 < 0.05 and ctx.mp1 == 0
      ctx.line1 = ("never played: at the cursor Sine %.2f, Gap %.2f, Whole %.2f dB; R Sine %s (want %.2f), Gap %s (want %.2f), Whole %s (want %.2f: its automation averaged); Tail Sine %s, Gap %s, Whole %s; R read %s (lowest seen %.2f), measured %s; at the cursor measured %s"):format(
        ctx.cs or -999, ctx.cg or -999, ctx.cw or -999, tostring(ctx.r1s), ctx.ws or -999, tostring(ctx.r1g), ctx.wg or -999, tostring(ctx.r1w), ctx.ww or -999,
        tostring(ctx.t1s), tostring(ctx.t1g), tostring(ctx.t1w), tostring(ctx.read1), ctx.minread, tostring(ctx.played1), tostring(ctx.mp1))
      -- play 12 to 20 s
      local P = ctx.tab
      reaper.SetEditCurPos2(P, 12, false, false)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(P) end)
      local function stop_at()
        if ctx.stop then return end
        if reaper.GetPlayStateEx(P) & 1 == 1 and reaper.GetPlayPositionEx(P) >= 20.2 then reaper.OnStopButtonEx(P); ctx.stopped_at = reaper.GetPlayPositionEx(P); return end
        reaper.defer(stop_at)
      end
      reaper.defer(stop_at)
      return nil, ("sections: %s\n%s\nplaying 12 to 20 s"):format(ctx.list0, ctx.line1), 9.5
    end,
    function(tab, ctx)
      if reaper.GetPlayStateEx(ctx.tab) & 1 == 1 then reaper.OnStopButtonEx(ctx.tab) end
      return nil, ("stopped at %.2f s; waiting for the sections to be worked out again"):format(ctx.stopped_at or -1), 8
    end,
    function(tab, ctx)
      local r = section("R")
      ctx.r2s, ctx.r2g, ctx.played2 = z_in(r, "Sine"), z_in(r, "Gap"), r and r.played
      -- the cursor back at 12 s, where playing started: measured there
      local f = EL.read("frame")
      ctx.mp2 = f and f.sm == 1 and math.abs(f.pos - 12) < 0.01 and f.mp
      ctx.ok2 = ctx.r2s and ctx.r2g and math.abs(ctx.r2s - ctx.ws) <= 0.75 and math.abs(ctx.r2g - ctx.wg) <= 0.2
        and ctx.played2 and ctx.played2 > 0.05 and ctx.played2 < 0.9 and type(ctx.mp2) == "number" and ctx.mp2 >= 0.9
      ctx.line2 = ("played 12-20 s: R Sine %s (want %.2f: %+.2f dB), Gap %s (want %.2f: %+.2f dB), measured %s; at the cursor (12 s) measured %s"):format(
        tostring(ctx.r2s), ctx.ws, (ctx.r2s or 0) - ctx.ws, tostring(ctx.r2g), ctx.wg, (ctx.r2g or 0) - ctx.wg, tostring(ctx.played2), tostring(ctx.mp2))
      -- a fader moved, no section on a page: Tail in its turn among twelve
      ctx.tw0 = z_in(section("Tail"), "Whole")
      reaper.SetMediaTrackInfo_Value(ctx.whole, "D_VOL", 0.5)
      watch_tail(ctx, "lat_turn", (ctx.tw0 or 0) - 5, -1)
      return nil, ctx.line2 .. "\nWhole's fader to -6 dB, no section shown", 16
    end,
    function(tab, ctx)
      -- Tail on the page: it goes first
      ctx.view = "20|30"
      reaper.SetExtState(EL.SECTION, "page_sect", ("%d|%s"):format(os.time() * 1000, ctx.view), false)
      return nil, ("Tail followed the fader in %.2f s in its turn; now Tail is on the page"):format(ctx.lat_turn or -1), 3
    end,
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(ctx.whole, "D_VOL", 1.0)
      watch_tail(ctx, "lat_view", (ctx.tw0 or 0) - 1, 1)
      return nil, "Whole's fader back to 0 dB, Tail shown", 4
    end,
    function(tab, ctx)
      ctx.view = nil
      reaper.DeleteExtState(EL.SECTION, "page_sect", false)
      ctx.ok3 = ctx.lat_view and ctx.lat_view >= 0 and ctx.lat_view <= 1.6 and ctx.lat_turn and ctx.lat_turn >= 0
      ctx.line3 = ("a fader moved while stopped, Tail's stage shows it: in its turn %.2f s (as the turn stands: up to 6 s among twelve), shown on a page %.2f s (<= 1.6)"):format(ctx.lat_turn or -1, ctx.lat_view or -1)
      send(ctx, { op = "sections", source = "markers#" })
      return nil, ctx.line3 .. "\nsections from # markers", 8
    end,
    function(tab, ctx)
      local s = EL.read("sections")
      ctx.lh = names(s)
      local a = section("A")
      ctx.ah = z_in(a, "Sine")
      ctx.okh = s and s.used == "markers#" and ctx.lh == "A 0-20, B 20-30" and ctx.ah and ctx.r2s and math.abs(ctx.ah - ctx.r2s) <= 0.05
      send(ctx, { op = "sections", source = "markers" })
      return nil, ("# markers: %s; A's Sine %s (R's %s)"):format(ctx.lh, tostring(ctx.ah), tostring(ctx.r2s)), 3
    end,
    function(tab, ctx)
      local s = EL.read("sections")
      ctx.lm = names(s)
      ctx.okm = s and s.used == "markers" and ctx.lm == "#A 0-12, cue 12-20, #B 20-25, y 26-30"
      send(ctx, { op = "sections", source = "regions" })
      return nil, ("every marker: %s"):format(ctx.lm), 3
    end,
    function(tab, ctx)
      local s, g = EL.read("sections"), EL.read("graph")
      local back = s and s.used == "regions" and #s.list == 12 and g.view.sections.source == "regions"
      ctx.stop = true
      EL.stop()
      local want0 = "P1 0-2, R 0-20, P2 2-4, P3 4-6, P4 6-8, P5 8-10, P6 10-12, P7 12-14, P8 14-16, P9 16-18, P10 18-20, Tail 20-30"
      local listok = ctx.list0 == want0
      local ok = listok and ctx.ok1 and ctx.ok2 and ctx.ok3 and ctx.okh and ctx.okm and back
      return ok, table.concat({
        "regions: " .. ctx.list0 .. (listok and "" or ("   <-- FAIL (want " .. want0 .. ")")),
        ctx.line1 .. (ctx.ok1 and "" or "   <-- FAIL"),
        ctx.line2 .. (ctx.ok2 and "" or "   <-- FAIL"),
        ctx.line3 .. (ctx.ok3 and "" or "   <-- FAIL"),
        ("# markers: %s; A's Sine %s against R's %s%s"):format(ctx.lh, tostring(ctx.ah), tostring(ctx.r2s), ctx.okh and "" or "   <-- FAIL"),
        ("every marker: %s%s"):format(ctx.lm, ctx.okm and "" or "   <-- FAIL (want #A 0-12, cue 12-20, #B 20-25, y 26-30)"),
        ("regions again: %s"):format(back and "12 sections" or "no   <-- FAIL"),
      }, "\n")
    end,
  },
}
