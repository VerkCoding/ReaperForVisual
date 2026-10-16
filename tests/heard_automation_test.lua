-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.3, automation: a bus whose pan sweeps left to right and whose fader rises from -6 dB to
-- 0 dB over 10 s, holding a centred sine. The API keeps reporting the bus at pan 0 and 0 dB
-- (measured), so the engine must evaluate the envelopes. Each frame's heard X of the sine must
-- match REAPER's balance pan (0 dB law) at that moment, and its heard Z must sit above or below
-- its own Z by what the pan and the fader do then. The master is muted.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json
local T30 = math.tan(math.rad(30))

return {
  name = "heard-automation",
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      local bus = L.track(tab, "Bus with automation", 1)
      L.item(L.track(tab, "sine centre", -1), L.env().signals .. L.SEP .. "sine1k_m12.wav", 0, 12)
      L.pan_sweep(bus, 0, 10, 1, -1)            -- envelope +1 -> -1 = pan left -> right
      reaper.SetOnlyTrackSelected(bus)
      L.act(40406, "volume envelope")
      local ve = reaper.GetTrackEnvelopeByName(bus, "Volume")
      local mode = reaper.GetEnvelopeScalingMode(ve)
      reaper.DeleteEnvelopePointRange(ve, -1, 100)
      reaper.InsertEnvelopePoint(ve, 0, reaper.ScaleToEnvelopeMode(mode, 0.5), 0, 0, false, true)
      reaper.InsertEnvelopePoint(ve, 10, reaper.ScaleToEnvelopeMode(mode, 1.0), 0, 0, false, true)
      reaper.Envelope_SortPoints(ve)
      ctx.tab = L.save_reopen(tab, H.tmpdir("heard-auto") .. SEP .. "auto.rpp")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_hauto")
      EL.run_later(ctx.cmd)
      _G.RFV_HA = { frames = {} }
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(ctx.tab, 0, false, false)
        reaper.OnPlayButtonEx(ctx.tab)
        local last = 0
        local function sample()
          local A = _G.RFV_HA
          if reaper.time_precise() - last >= 0.1 then
            last = reaper.time_precise()
            local f = J.decode(reaper.GetExtState(EL.SECTION, "frame"))
            if f and f.play == 1 and f.a then A.frames[#A.frames + 1] = { pos = f.pos, a = f.a, h = f.h } end
            if f and f.play == 1 and f.pos >= 10.5 then
              A.dpan = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(ctx.tab, 0), "D_PAN")
              A.done = true; reaper.OnStopButtonEx(ctx.tab); return
            end
          end
          reaper.defer(sample)
        end
        sample()
      end)
      return nil, "bus with pan and volume automation, engine started, playing 10.5 s", 13
    end,
    function(tab, ctx)
      EL.stop()
      local A = _G.RFV_HA
      if not A.done then return false, "playback did not finish" end
      local worst_x, worst_z, n, sample_line = 0, 0, 0, ""
      for _, f in ipairs(A.frames) do
        local own, hd = f.a[2], f.h and f.h[2]
        if f.pos >= 2.5 and f.pos <= 9.8 and own ~= J.null and hd and hd ~= J.null and hd[1] ~= J.null then
          local p = -1 + 2 * f.pos / 10                   -- the bus pan now
          local vol = 0.5 + 0.5 * f.pos / 10               -- linear points: the fader now (in fader scaling)
          local gl, gr = (p <= 0 and 1 or 1 - p), (p >= 0 and 1 or 1 + p)
          local x = math.deg(math.atan((gr - gl) / (gl + gr) * T30))
          n = n + 1
          worst_x = math.max(worst_x, math.abs(hd[1] - x))
          -- the fader envelope is linear in fader scaling, not in gain: judge the pan part exactly
          -- and the level change up to the fader's value at this point read back from REAPER
          local dz = hd[2] - own[2]
          local pan_db = 10 * math.log((gl * gl + gr * gr) / 2, 10)
          f.dz_pan = dz - pan_db
          if math.abs(f.pos - 5) < 0.06 then sample_line = (" at %.2f s: pan %+.2f -> X %.2f (heard %.2f), level change %+.2f dB of which pan %+.2f"):format(f.pos, p, x, hd[1], dz, pan_db) end
        end
      end
      -- the fader part must rise smoothly from about -6 dB to 0 dB
      local first, last
      for _, f in ipairs(A.frames) do if f.dz_pan then first = first or f; last = f end end
      local ok = n > 50 and worst_x < 0.5 and first and last and first.dz_pan < -2 and last.dz_pan > -1 and math.abs(A.dpan) < 1e-9
      return ok, ("%d frames judged: heard X off theory by at most %.3f deg;%s; the fader part rose from %.2f dB (%.1f s) to %.2f dB (%.1f s); the API's D_PAN of the bus read %.3f all along"):format(
        n, worst_x, sample_line, first and first.dz_pan or 0, first and first.pos or 0, last and last.dz_pan or 0, last and last.pos or 0, A.dpan or 99), 1
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
