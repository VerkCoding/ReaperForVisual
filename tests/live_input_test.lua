-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.4, live inputs (owner's decision 3, 2026-10-11). An armed track meters its input, so:
--   * armed and monitored, panned hard left: its own X is estimated through its pan: -30 deg,
--     although its meter reads the same on both sides;
--   * the same panned hard right as the only input of a bus: heard exactly where the bus is,
--     +30 deg, from the bus's meter;
--   * armed but not monitored: unknown (null).
-- The signal is whatever input 1 of the audio interface carries (its noise floor will do); the
-- master is muted, so nothing is heard.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json

local function arm(tr, monitor)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", monitor and 1 or 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
end

return {
  name = "live-input",
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      arm(L.track(tab, "live, pan left", 0, { pan = -1 }), true)
      L.track(tab, "bus of one", 1)
      arm(L.track(tab, "live, pan right, alone in its bus", -1, { pan = 1 }), true)
      arm(L.track(tab, "armed, not monitored"), false)
      ctx.tab = L.save_reopen(tab, H.tmpdir("live-input") .. SEP .. "live.rpp")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_live")
      EL.run_later(ctx.cmd)
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(ctx.tab) end) -- keeps the audio device open
      return nil, "3 armed tracks, engine started", 4
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local raw = { reaper.Track_GetPeakInfo(reaper.GetTrack(tab, 0), 0), reaper.Track_GetPeakInfo(reaper.GetTrack(tab, 0), 1) }
      reaper.OnStopButtonEx(tab)
      EL.stop()
      for i = 0, reaper.CountTracks(tab) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(tab, i), "I_RECARM", 0) end
      if not f or not f.a then return false, "no frame" end
      local function has(list, i) for _, v in ipairs(list or {}) do if v == i then return true end end return false end
      local left, bus, right, quiet = f.a[1], f.a[2], f.h[3], f.a[4]
      local ok = left ~= J.null and math.abs(left[1] + 30) < 0.5 and has(f.ae, 0)
        and right ~= J.null and math.abs(right[1] - 30) < 0.5 and has(f.hb, 2)
        and quiet == J.null
      return ok, ("meter of the left one: L %.4g R %.4g (its input); own X estimated %s (estimated list %s); the bus %s; the right one heard via its bus at %s (via-bus list %s); not monitored: %s"):format(
        raw[1], raw[2], left ~= J.null and ("%.1f deg, %.1f dB"):format(left[1], left[2]) or "null", J.encode(f.ae),
        bus ~= J.null and ("%.1f deg"):format(bus[1]) or "null", right ~= J.null and ("%.1f deg, %.1f dB"):format(right[1], right[2]) or "null",
        J.encode(f.hb), quiet == J.null and "null" or J.encode(quiet)), 1
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
