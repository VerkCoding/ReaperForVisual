-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.1: the meter pipeline inside the running engine, on REAPER's real meters.
--   * the decay step and the refresh are measured from the readings, and their product matches
--     REAPER's vudecay setting (30 dB/s here);
--   * a sine at pan +0.5 sits at the tangent-law azimuth (+10.89 deg); noise in the centre at 0;
--   * a part that stopped two seconds ago is silent (null), not a fading level (or under -90 dB:
--     an early refresh on the decay tail, step 10a).
-- The master is at -inf, so nothing is heard.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")

return {
  name = "meter-live",
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "D_VOL", 0)
      local S = L.env().signals .. L.SEP
      L.item(L.track(tab, "sine pan +0.5", 0, { pan = 0.5 }), S .. "sine1k_m12.wav", 0, 20)
      L.item(L.track(tab, "noise centre"), S .. "noise_m20.wav", 0, 20)
      L.item(L.track(tab, "burst 0-3 s"), S .. "noise_m20.wav", 0, 3)
      ctx.tab = L.save_reopen(tab, H.tmpdir("meter-live") .. SEP .. "meter.rpp")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_meter")
      EL.run_later(ctx.cmd)
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(ctx.tab, 0, false, false)
        reaper.OnPlayButtonEx(ctx.tab)
      end)
      return nil, "3 tracks, engine started, playing", 7.0
    end,
    function(tab, ctx)
      local raw = reaper.GetExtState(EL.SECTION, "frame")
      local f = EL.read("frame")
      reaper.OnStopButtonEx(tab)
      EL.stop()
      if not f or not f.md then return false, "no frame with meter data" end
      local md, a = f.md, f.a
      local sine, noise, burst = a[1], a[2], a[3]
      local ok_decay = md.measured and math.abs(md.step - 1.4) < 0.02 and math.abs(md.refresh_ms - 46.7) < 3
        and math.abs(md.decay - md.vudecay) < 1.5
      local ok_x = sine and sine ~= EL.json.null and math.abs(sine[1] - 10.89) < 0.2 and noise and math.abs(noise[1]) < 1
      -- silent, or under -90 dB: now and then a refresh that comes early falls less than the
      -- decay step and is taken for a fresh peak on the tail (2 of 14 suite runs read -96 and -98
      -- dB four seconds on; step 10a); far under anything the stage shows
      local ok_silent = burst == EL.json.null or (burst[2] ~= EL.json.null and burst[2] < -90)
      return ok_decay and ok_x and ok_silent, ("at %.1f s: decay step %.3f dB per refresh of %.1f ms = %.1f dB/s (vudecay %s, measured %s); "
        .. "sine pan +0.5 X %s Z %s; noise X %s Z %s; burst (stopped at 3 s) %s; frame %d bytes"):format(
        f.pos, md.step, md.refresh_ms, md.decay, tostring(md.vudecay), tostring(md.measured),
        tostring(sine and sine[1]), tostring(sine and sine[2]), tostring(noise and noise[1]), tostring(noise and noise[2]),
        burst == EL.json.null and "silent" or EL.json.encode(burst), #raw), 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
