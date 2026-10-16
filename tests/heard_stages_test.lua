-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5 review (G1-G5), live: every volume and pan stage of a bus, mute, solo, side sends and
-- sends taken before the fader, through the running engine. The ruler is REAPER's own meter: a
-- bus without FX whose only input is one track outputs exactly that track as heard, so the
-- track's heard X and Z must match the bus's own (both read from meters, the master at 0 dB and
-- centred). Each case is a bus of its own:
--   trim      a Trim Volume envelope at -6 dB
--   prevol    a Volume (Pre-FX) envelope at -6 dB
--   prepan    pan knob +0.2 and a Pan (Pre-FX) envelope stored -0.4 (right 0.4)
--   width     stereo pan mode, width knob 0.5 and a Width envelope at 0.6, a left-only source
--   vca       the bus follows a VCA lead at -6 dB
--   read      Read mode: fader -3 dB with a Volume envelope at -6 dB, pan knob -0.3 with a Pan
--             envelope stored +0.2 (left 0.2): REAPER combines them in every mode (measured)
--   presend   a track at -10 dB panned left 0.5, master send off, sent before its fader to a bus
--   side      a bus with +6 dB of FX holding one track, and a side send into it from another
--             track: the track's heard Z must sit 6 dB above its own (the side send must not
--             count as the track's)
--   silentfx  a bus whose FX silence it (-150 dB): its track is heard nowhere
--   muted     a bus with its mute button on; muteenv: a bus with a Mute envelope at 0
-- Then the trim case's track is soloed in place for 3 s: it alone (with its bus) is heard.
-- The master is muted (heard levels go through its fader, which stays at 0 dB).

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json

local PLAY = 7.0      -- seconds before the solo phase
local SOLO = 3.5      -- seconds of solo

local function env_const(env, v, scaled)
  local m = reaper.GetEnvelopeScalingMode(env)
  local x = scaled and reaper.ScaleToEnvelopeMode(m, v) or v
  reaper.DeleteEnvelopePointRange(env, -1, 100)
  reaper.InsertEnvelopePoint(env, 0, x, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, 60, x, 0, 0, false, true)
  reaper.Envelope_SortPoints(env)
end
local function show_env(tr, action, name)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(action, 0)
  return reaper.GetTrackEnvelopeByName(tr, name)
end
local function width_env(tr, v)
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local env = ("<WIDTHENV2\nEGUID %s\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 %s 0\nPT 60 %s 0\n>\n"):format(reaper.genGuid(""), v, v)
  local n
  chunk, n = chunk:gsub("\n>%s*$", "\n" .. env .. ">\n", 1)
  reaper.SetTrackStateChunk(tr, chunk, false)
  return reaper.GetTrackEnvelopeByName(tr, "Width")
end
local function db(x) return 20 * math.log(x, 10) end

return {
  name = "heard-stages",
  steps = {
    function(tab, ctx)
      local S = L.env().signals .. SEP
      local sine, lonly = S .. "sine1k_m12.wav", S .. "sine_L_only.wav"
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      local made = {}
      local function case(name, src)
        local bus = L.track(tab, name .. " bus", 1)
        local tr = L.track(tab, name .. " src", -1)
        L.item(tr, src or sine, 0, 60)
        return bus, tr
      end
      local b = case("trim")
      made.trim = show_env(b, 42020, "Trim Volume"); env_const(made.trim, 0.5, true)
      b = case("prevol")
      made.prevol = show_env(b, 40408, "Volume (Pre-FX)"); env_const(made.prevol, 0.5, true)
      b = case("prepan")
      made.prepan = show_env(b, 40409, "Pan (Pre-FX)"); env_const(made.prepan, -0.4, false)
      reaper.SetMediaTrackInfo_Value(b, "D_PAN", 0.2)
      b = case("width", lonly)
      reaper.SetMediaTrackInfo_Value(b, "I_PANMODE", 5)
      made.width = width_env(b, 0.6)
      reaper.SetMediaTrackInfo_Value(b, "D_WIDTH", 0.5)
      local lead = L.track(tab, "vca lead", 0, { vol = 0.5 })
      b = case("vca")
      reaper.GetSetTrackGroupMembership(lead, "VOLUME_VCA_LEAD", 1, 1)
      reaper.GetSetTrackGroupMembership(b, "VOLUME_VCA_FOLLOW", 1, 1)
      made.vca = reaper.GetSetTrackGroupMembership(b, "VOLUME_VCA_FOLLOW", 0, 0) == 1
      b = case("read")
      made.read = show_env(b, 40406, "Volume"); env_const(made.read, 0.5, true)
      local pe = show_env(b, 40407, "Pan"); env_const(pe, 0.2, false)
      reaper.SetMediaTrackInfo_Value(b, "D_VOL", 10 ^ (-3 / 20))
      reaper.SetMediaTrackInfo_Value(b, "D_PAN", -0.3)
      reaper.SetMediaTrackInfo_Value(b, "I_AUTOMODE", 1)
      local ps = L.track(tab, "presend src", 0, { vol = 10 ^ (-10 / 20), pan = -0.5, mainsend = false })
      L.item(ps, sine, 0, 60)
      local pb = L.track(tab, "presend bus", 0)
      L.send(ps, pb, 1, { mode = 3 })
      b = case("side")
      reaper.SetMediaTrackInfo_Value(reaper.GetTrack(tab, reaper.CountTracks(tab) - 1), "D_VOL", 10 ^ (-10 / 20))
      local fx = L.fx(b, "JS: Volume Adjustment")
      L.set(b, fx, "Max Volume (dB)", 24) -- its default 0 dB cap would make the +6 dB depend on level
      L.set(b, fx, "Adjustment (dB)", 6)
      local x = L.track(tab, "side sender", 0, { vol = 10 ^ (-5 / 20) }) -- about as loud as the track: a counted side send would add 3 dB
      L.item(x, L.env().signals .. SEP .. "noise_m20.wav", 0, 60)
      L.send(x, b, 1)
      b = case("silentfx")
      fx = L.fx(b, "JS: Volume Adjustment")
      L.set(b, fx, "Adjustment (dB)", -150)
      b = case("muted")
      reaper.SetMediaTrackInfo_Value(b, "B_MUTE", 1)
      b = case("muteenv")
      made.muteenv = show_env(b, 40867, "Mute"); env_const(made.muteenv, 0, false)
      local ok = true
      for k, v in pairs(made) do if not v then ok = false; ctx.missing = (ctx.missing or "") .. k .. " " end end
      if not ok then return false, "could not build: " .. ctx.missing end
      ctx.tab = L.save_reopen(tab, H.tmpdir("heard-stages") .. SEP .. "stages.rpp")
      local P = ctx.tab
      local idx = {}
      for i = 0, reaper.CountTracks(P) - 1 do
        local _, nm = reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(P, i), "P_NAME", "", false)
        idx[nm] = i
      end
      ctx.idx = idx
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_stages")
      EL.run_later(ctx.cmd)
      _G.RFV_HS = { frames = {} }
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(P, 0, false, false)
        reaper.OnPlayButtonEx(P)
        local t0, last, soloed = reaper.time_precise(), 0, false
        local solo_tr = reaper.GetTrack(P, idx["trim src"])
        local function sample()
          local A = _G.RFV_HS
          local now = reaper.time_precise()
          if not soloed and now - t0 >= PLAY then soloed = true; A.solo_t = now - t0; reaper.SetMediaTrackInfo_Value(solo_tr, "I_SOLO", 2) end
          if now - last >= 0.1 then
            last = now
            local f = J.decode(reaper.GetExtState(EL.SECTION, "frame"))
            if f and f.play == 1 and f.a then A.frames[#A.frames + 1] = { t = now - t0, f = f } end
          end
          if now - t0 >= PLAY + SOLO then
            reaper.SetMediaTrackInfo_Value(solo_tr, "I_SOLO", 0)
            A.done = true; reaper.OnStopButtonEx(P); return
          end
          reaper.defer(sample)
        end
        sample()
      end)
      return nil, ("built %d tracks, engine started, playing %.1f s (solo from %.1f s)"):format(reaper.CountTracks(P), PLAY + SOLO, PLAY), PLAY + SOLO + 3
    end,
    function(tab, ctx)
      EL.stop()
      local A = _G.RFV_HS
      if not A.done then return false, "playback did not finish" end
      local I = ctx.idx
      local function med(t)
        if #t == 0 then return nil end
        table.sort(t)
        return #t % 2 == 1 and t[(#t + 1) // 2] or (t[#t // 2] + t[#t // 2 + 1]) / 2
      end
      local function field(f, name, k)
        local v = f[name] and f[name][k + 1]
        if not v or v == J.null then return nil end
        return v
      end
      local function has(list, k) for _, v in ipairs(list or {}) do if v == k then return true end end return false end
      local out, ok = {}, true
      local function before_solo(fr) return fr.t >= 2.5 and fr.t < PLAY - 0.1 end
      -- heard of the track against the bus's own
      for _, name in ipairs({ "trim", "prevol", "prepan", "width", "vca", "read", "presend" }) do
        local src, bus = I[name .. " src"], I[name .. " bus"]
        local dz, dx, n = {}, {}, 0
        for _, fr in ipairs(A.frames) do
          if before_solo(fr) then
            local h, a = field(fr.f, "h", src), field(fr.f, "a", bus)
            if h and a and h[2] ~= J.null and a[2] ~= J.null then
              n = n + 1
              dz[#dz + 1] = math.abs(h[2] - a[2])
              if h[1] ~= J.null and a[1] ~= J.null then dx[#dx + 1] = math.abs(h[1] - a[1]) end
            end
          end
        end
        local z, x = med(dz), med(dx)
        local good = n >= 20 and z and z <= 0.3 and (not x or x <= 0.5)
        ok = ok and good
        out[#out + 1] = ("  %-8s heard vs its bus's own: Z %s dB, X %s deg (%d frames)%s"):format(name,
          z and ("%.2f"):format(z) or "-", x and ("%.2f"):format(x) or "-", n, good and "" or "  <-- FAIL")
      end
      -- the side case: heard 6 dB above own
      do
        local src = I["side src"]
        local d = {}
        for _, fr in ipairs(A.frames) do
          if before_solo(fr) then
            local h, a = field(fr.f, "h", src), field(fr.f, "a", src)
            if h and a and h[2] ~= J.null and a[2] ~= J.null then d[#d + 1] = h[2] - a[2] end
          end
        end
        local m = med(d)
        -- what the meters say, to see where any difference comes from: the bus's own over the
        -- sum of what enters it (the track, and the sender through its send at 0 dB)
        local zs, zx, zb = {}, {}, {}
        for _, fr in ipairs(A.frames) do
          if before_solo(fr) then
            local a1, a2, a3 = field(fr.f, "a", src), field(fr.f, "a", I["side sender"]), field(fr.f, "a", I["side bus"])
            if a1 and a2 and a3 then zs[#zs + 1], zx[#zx + 1], zb[#zb + 1] = a1[2], a2[2], a3[2] end
          end
        end
        local ms, mx, mb = med(zs), med(zx), med(zb)
        -- The engine must give the track the bus's measured gain over ALL its inputs (the side
        -- send counted), whatever the meters' own errors: white noise reads ~5 dB high and a sine
        -- 1.5 dB low with a crest model fitted on music, so the 6 dB itself is only approached.
        local over = ms and mx and mb and mb - 10 * math.log(10 ^ (ms / 10) + 10 ^ (mx / 10), 10)
        local ignored = ms and mb and mb - ms
        if over then
          out[#out + 1] = ("  side     own Z: track %.2f, sender %.2f, bus %.2f dB: the bus over all its inputs %+.2f dB, over the track alone %+.2f"):format(
            ms, mx, mb, over, ignored)
        end
        local good = m and over and math.abs(m - over) <= 0.2 and math.abs(m - ignored) > 3
        ok = ok and good
        out[#out + 1] = ("  side     heard - own: %s dB (the FX are +6 dB; must equal the bus over all its inputs)%s"):format(m and ("%+.2f"):format(m) or "-", good and "" or "  <-- FAIL")
      end
      -- silenced: heard nowhere, listed in hm
      for _, name in ipairs({ "silentfx", "muted", "muteenv" }) do
        local src = I[name .. " src"]
        local n, heard, listed, owned = 0, 0, 0, 0
        for _, fr in ipairs(A.frames) do
          if fr.t >= 3.0 and fr.t < PLAY - 0.1 then
            n = n + 1
            if field(fr.f, "h", src) then heard = heard + 1 end
            if has(fr.f.hm, src) then listed = listed + 1 end
            if field(fr.f, "a", src) then owned = owned + 1 end
          end
        end
        -- a folder muted from the start: REAPER does not process its child at all (no own sound);
        -- muted by an envelope, the child plays into it and is listed as silenced
        local good = n >= 20 and heard == 0 and (name == "silentfx" or listed >= n * 0.9 or owned == 0)
        ok = ok and good
        out[#out + 1] = ("  %-8s heard in %d of %d frames (0), listed as silenced in %d, own sound in %d%s"):format(name, heard, n, listed, owned, good and "" or "  <-- FAIL")
      end
      -- solo phase: the soloed track and its bus heard, the others not; solo flag set
      do
        local n, wrong, flag = 0, 0, 0
        local solo_src, solo_bus = I["trim src"], I["trim bus"]
        for _, fr in ipairs(A.frames) do
          if A.solo_t and fr.t >= A.solo_t + 0.4 then
            n = n + 1
            if fr.f.solo == 1 then flag = flag + 1 end
            for name, k in pairs(I) do
              local h = field(fr.f, "h", k)
              local should = (k == solo_src or k == solo_bus)
              if name:find("src$") or name:find("bus$") or name == "side sender" then
                if should and not h and field(fr.f, "a", k) then wrong = wrong + 1 end
                if not should and h then wrong = wrong + 1 end
              end
            end
          end
        end
        local good = n >= 15 and wrong == 0 and flag == n
        ok = ok and good
        out[#out + 1] = ("  solo     %d frames, solo flag in %d, tracks heard against the rule: %d%s"):format(n, flag, wrong, good and "" or "  <-- FAIL")
      end
      local cost = A.frames[#A.frames] and A.frames[#A.frames].f.cost
      out[#out + 1] = cost and ("  engine cost: tick %.3f ms median, %.2f p95, %.2f max"):format(cost.ms_med, cost.ms_p95, cost.ms_max) or ""
      EL.unregister(ctx.path)
      return ok, table.concat(out, "\n")
    end,
  },
}
