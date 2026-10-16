-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 7, method: engine/rfv_spectrum.lua and engine/rfv_ymap.lua on the test signals
-- (tools/make_signals.py), read through track accessors in a temporary tab. Known answers:
-- a 1 kHz sine is at 1 kHz; 500 Hz left and 3 kHz right, equal powers, at their geometric mean
-- (1,224.7 Hz) with correlation 0; white noise at 7,408.5 Hz (the calib truth); the noise against
-- itself inverted at correlation -1; one channel alone reads correlation 1, as the truth does.
-- Then: a pan matrix, a bus adding two parts by the power each brings, a part with no files (a
-- virtual instrument) as the unknown share, FX as the unseen share; the map filling within its
-- budget and starting again when an item moves.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local SP = dofile(ENG .. "rfv_spectrum.lua")
local YM = dofile(ENG .. "rfv_ymap.lua")

local function oct(a, b) return (a and b) and math.abs(math.log(a / b, 2)) or math.huge end

return {
  name = "spectrum-logic",
  cleanup = function(ctx)
    for _, a in ipairs(ctx.accs or {}) do reaper.DestroyAudioAccessor(a) end
    ctx.accs = nil
    if ctx.map then YM.destroy(ctx.map); ctx.map = nil end
  end,
  steps = { function(tab, ctx)
    local sig = L.env().signals .. SEP
    local out, bad = {}, 0
    local function check(what, ok, detail)
      if not ok then bad = bad + 1 end
      out[#out + 1] = ("  %-50s %s%s"):format(what, detail, ok and "" or "   <-- FAIL")
    end
    ctx.accs = {}
    local an = SP.new()
    -- stats of a file over 2-10 s, 10 windows a second
    local function read(file, start)
      local tr = L.track(tab, file, 0)
      L.item(tr, sig .. file, 0, 12)
      local acc = reaper.CreateTrackAudioAccessor(tr)
      ctx.accs[#ctx.accs + 1] = acc
      local s = SP.zero()
      local t0 = reaper.time_precise()
      for i = 0, 79 do SP.window(an, acc, (start or 2) + i * 0.1, s) end
      return s, 1000 * (reaper.time_precise() - t0) / 80, tr, acc
    end
    local sine, ms = read("sine1k_m12.wav")
    check("1 kHz sine: Y", oct(SP.y(sine), 1000) < 0.01, ("%.1f Hz"):format(SP.y(sine) or -1))
    check("... width (a mono part)", math.abs(SP.corr(sine) - 1) < 1e-6, ("corr %.4f"):format(SP.corr(sine)))
    -- step 9a: the stats' powers over SP.SCALE and the windows are mean squares (peak 0.25 on
    -- both channels: 2 x 0.25^2 / 2 = 0.0625, -12.04 dB)
    local p_db = 10 * math.log((sine[1] + sine[2]) / (sine[7] * SP.SCALE), 10)
    check("... its power through SP.SCALE", math.abs(p_db + 12.04) < 0.1, ("%.2f dB (want -12.04)"):format(p_db))
    local st = read("st_500L_3kR.wav")
    check("500 Hz left, 3 kHz right: Y", oct(SP.y(st), 1224.7) < 0.01, ("%.1f Hz (want 1224.7)"):format(SP.y(st) or -1))
    check("... width", math.abs(SP.corr(st)) < 0.02, ("corr %.4f"):format(SP.corr(st)))
    local noise = read("noise_m20.wav")
    check("white noise: Y", oct(SP.y(noise), 7408.5) < 0.02, ("%.1f Hz (calib truth 7408.5)"):format(SP.y(noise) or -1))
    local anti = read("noise_antiphase.wav")
    check("noise against itself inverted: width", math.abs(SP.corr(anti) + 1) < 1e-6, ("corr %.4f"):format(SP.corr(anti)))
    local lonly = read("sine_L_only.wav")
    check("a sine in the left channel only", math.abs(SP.corr(lonly) - 1) < 1e-9 and oct(SP.y(lonly), 1000) < 0.01,
      ("corr %.4f, %.1f Hz"):format(SP.corr(lonly), SP.y(lonly) or -1))
    local none = SP.zero()
    local acc1 = ctx.accs[1]
    check("a window past the items", SP.window(an, acc1, 20, none) == "none" and none[7] == 0, "none, nothing added")
    check("cost of a window", ms < 2, ("%.3f ms"):format(ms))

    -- pan matrices (rfv_heard.lua's form: out L = ll*L + rl*R, out R = lr*L + rr*R)
    local left = SP.through({ 1, 0, 0, 0 }, st)
    check("left channel only: Y", oct(SP.y(left), 500) < 0.01, ("%.1f Hz"):format(SP.y(left) or -1))
    local mono = SP.through({ 0.5, 0.5, 0.5, 0.5 }, st)
    check("summed to mono: Y and width", oct(SP.y(mono), 1224.7) < 0.01 and math.abs(SP.corr(mono) - 1) < 1e-9,
      ("%.1f Hz, corr %.4f"):format(SP.y(mono) or -1, SP.corr(mono)))
    local swapped = SP.through({ 0, 1, 1, 0 }, st)
    check("channels swapped: the right channel holds 500 Hz", oct(SP.y(SP.through({ 0, 0, 0, 1 }, swapped)), 500) < 0.01, "ok")

    -- a bus: 1 sine (track 2), 2 noise (track 3), 3 the bus (no files), 4 a part with no files
    -- (track 4, into the bus): equal powers from 2 and 3; 4 brings as much as both together
    local id = { 1, 0, 0, 1 }
    local src = { nil, sine, noise, nil }
    local M = { id, id, id, id }
    local P = { 2, 1, 1, 2 }
    local dry, way = { 0, 1, 1, 1 }, {}
    local S, u, f = SP.compose(4, src, M, P, { false, false, true, false }, dry, way, nil, nil)
    -- the bus without the unknown part: sine and noise at equal powers
    local want = 2 ^ ((math.log(1000, 2) + math.log(SP.y(noise), 2)) / 2)
    check("a bus: two parts at equal powers", oct(SP.y(S[1]), want) < 0.02, ("%.1f Hz (want %.1f)"):format(SP.y(S[1]) or -1, want))
    check("... the unknown share (a part with no files)", math.abs(u[1] - 0.5) < 1e-9, ("%.3f (want 0.5)"):format(u[1]))
    check("... the unseen share (the noise track has FX)", math.abs(f[1] - 0.25) < 1e-9, ("%.3f (want 0.25)"):format(f[1]))
    check("... a part with no files has no Y", S[4] == nil and u[4] == 1, ("S %s, u %s"):format(tostring(S[4]), tostring(u[4])))
    -- not measured (stopped): the files' own powers weigh
    local S2 = SP.compose(4, src, M, { nil, nil, nil, nil }, { false, false, false, false }, dry, way, nil, nil)
    local ps, pn = SP.power(sine), SP.power(noise)
    local want2 = 2 ^ ((ps * math.log(1000, 2) + pn * math.log(SP.y(noise), 2)) / (ps + pn))
    check("stopped: weighed by the files' powers", oct(SP.y(S2[1]), want2) < 0.02, ("%.1f Hz (want %.1f)"):format(SP.y(S2[1]) or -1, want2))
    local G, gu = SP.combine({ { S = sine, u = 0, f = 0, w = 1 }, { S = noise, u = 0, f = 0, w = 1 }, { S = nil, u = 1, f = 0, w = 2 } })
    check("a display group: as the bus", oct(SP.y(G), want) < 0.02 and math.abs(gu - 0.5) < 1e-9, ("%.1f Hz, unknown %.2f"):format(SP.y(G) or -1, gu))
    -- still to read (step 8 review): the sine's files half read, the noise's not at all (its
    -- stats stand for what is read), the part with no files has nothing to read; the bus reads
    -- nothing itself, so it is what its inputs bring, by power: (0.5 x 1 + 1 x 1 + 0 x 2) / 4
    local _, _, _, r3 = SP.compose(4, src, M, P, { false, false, false, false }, dry, way, nil, nil, nil, { 1, 0.5, 0, 1 })
    check("still to read: a bus by what its inputs bring", math.abs(r3[1] - 0.375) < 1e-9 and math.abs(r3[2] - 0.5) < 1e-9 and r3[3] == 1 and r3[4] == 0,
      ("bus %.3f (want 0.375), sine %.2f, noise %.2f, no files %.2f"):format(r3[1], r3[2], r3[3], r3[4]))
    local _, _, _, r4 = SP.compose(4, src, M, P, { false, false, false, false }, dry, way, nil, nil)
    check("... nothing to read when every window is read", r4[1] == 0 and r4[2] == 0, ("bus %.2f"):format(r4[1]))
    local _, _, _, gr = SP.combine({ { S = sine, u = 0, f = 0, r = 0.5, w = 1 }, { S = noise, u = 0, f = 0, r = 0, w = 3 } })
    check("... a display group by power", math.abs(gr - 0.125) < 1e-9, ("%.3f (want 0.125)"):format(gr))

    -- the map: a 4 s sine at 1 s; fill around 2 s; move it to 6 s: the map starts again
    local tr = L.track(tab, "map", 0)
    local it = L.item(tr, sig .. "sine1k_m12.wav", 1, 4)
    local guid = reaper.GetTrackGUID(tr)
    ctx.map = YM.new()
    local map = ctx.map
    local need = { { tr, guid } }
    local t0 = reaper.time_precise()
    YM.work(map, tab, need, 2, true, 10, 0.002)
    local spent = 1000 * (reaper.time_precise() - t0)
    check("one cycle keeps to its budget (2 ms)", spent < 3, ("%.2f ms, %d windows"):format(spent, map.windows))
    for _ = 1, 40 do YM.work(map, tab, need, 2, true, 10, 0.002) end
    local s1, cover = YM.stats(map, guid, 0, 2)
    check("the readout around 2 s is read", s1 ~= nil and cover == 1 and oct(SP.y(s1), 1000) < 0.01, ("cover %.2f, %.1f Hz"):format(cover, s1 and SP.y(s1) or -1))
    check("the whole song read in the background", YM.progress(map, need, 10) == 1, ("%.2f"):format(YM.progress(map, need, 10)))
    -- the move, as a user makes it: between two of the engine's cycles (REAPER moves the state
    -- counter and the accessors' state after the call that edits, not inside it)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", 6)
    ctx.out, ctx.bad, ctx.need, ctx.guid, ctx.check, ctx.oct = out, bad, need, guid, check, oct
    return nil, nil, 0.3
  end,
  function(tab, ctx)
    local map, need, guid = ctx.map, ctx.need, ctx.guid
    for _ = 1, 40 do YM.work(map, tab, need, 2, true, 10, 0.002) end
    -- the fingerprint names each take's source by its file, never by a pointer (step 9b
    -- acceptance: a project opened again gets new source objects, and every track read as changed)
    local fp = YM.fingerprint(reaper.GetTrack(tab, reaper.CountTracks(tab) - 1))
    local fpok = not fp:find("userdata", 1, true) and fp:find("sine1k_m12.wav", 1, true) ~= nil
    if not fpok then ctx.bad = ctx.bad + 1 end
    ctx.out[#ctx.out + 1] = ("  %-50s %s%s"):format("the fingerprint: the source's file, no pointer", fp:sub(1, 60) .. "...", fpok and "" or "   <-- FAIL")
    -- ... and the same with the media set offline (REAPER does it in the background with
    -- "offlineinact"; an offline source reads length 0: step 10b)
    reaper.Main_OnCommand(40100, 0) -- Item: Set all media offline
    local fpoff = YM.fingerprint(reaper.GetTrack(tab, reaper.CountTracks(tab) - 1))
    reaper.Main_OnCommand(40101, 0) -- Item: Set all media online
    if fpoff ~= fp then ctx.bad = ctx.bad + 1 end
    ctx.out[#ctx.out + 1] = ("  %-50s %s%s"):format("... the same with the media offline", fpoff == fp and "same" or "changed", fpoff == fp and "" or "   <-- FAIL")
    local s3 = YM.stats(map, guid, 0, 2)
    local s4 = YM.stats(map, guid, 6.5, 8)
    local ok = s3 == nil and s4 ~= nil and ctx.oct(SP.y(s4), 1000) < 0.01
    if not ok then ctx.bad = ctx.bad + 1 end
    ctx.out[#ctx.out + 1] = ("  %-50s %s%s"):format("item moved: the map starts again",
      ("0-2 s now %s, 6.5-8 s %s"):format(s3 and "sound" or "silent", s4 and ("%.1f Hz"):format(SP.y(s4)) or "nothing"), ok and "" or "   <-- FAIL")
    -- step 9b review: a level counts every window read, silent ones and blocks with no item too
    -- (the sine from 6 s: over 4-8 s half as loud as over 6-8 s); blocks left out (those that
    -- played) are not read into it; silent there tells itself from not read by the windows read
    local function chk(what, good, detail)
      if not good then ctx.bad = ctx.bad + 1 end
      ctx.out[#ctx.out + 1] = ("  %-50s %s%s"):format(what, detail, good and "" or "   <-- FAIL")
    end
    local done = YM.progress(map, need, 10)
    local sa, _, _, wa, ta = YM.stats(map, guid, 6, 8)
    local sb, _, _, wb, tb = YM.stats(map, guid, 4, 8)
    local la, lb = sa and SP.power(sa) / wa, sb and SP.power(sb) / wb
    chk("silence counts: half the range, half the power", done == 1 and la and lb and math.abs(10 * math.log(lb / la, 10) + 10 * math.log(2, 10)) < 0.01 and wa == 20 and wb == 40 and ta == 1 and tb == 1,
      ("read %.2f; 6-8 s %d windows, 4-8 s %d; %+.3f dB (want -3.010)"):format(done, wa, wb, la and lb and 10 * math.log(lb / la, 10) or 0))
    local skip = { [12] = true, [13] = true, [14] = true, [15] = true }
    local sc, _, _, wc = YM.stats(map, guid, 4, 8, skip)
    chk("... the blocks that played left out: silent there", sc == nil and wc == 20, ("%s, %d windows"):format(sc and "sound" or "silent", wc))
    local fresh = YM.new()
    local sd, _, _, wd, td = YM.stats(fresh, guid, 4, 8)
    chk("... not read at all: nothing, no windows", sd == nil and wd == 0 and td == 0, ("%d windows, %.2f touched"):format(wd, td))
    return ctx.bad == 0, table.concat(ctx.out, "\n")
  end },
}
