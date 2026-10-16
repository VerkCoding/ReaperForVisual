-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Records REAPER's own meter readings while a test project plays, the way the engine reads them
-- (every track's Track_GetPeakInfo, every defer tick), so tools/meter_reference.py can fit and
-- judge the crest model on real readings instead of an emulation (review of step 5, G7).
--   python tools/rfv_test.py tests/meter_record_test.lua --set fixture=band --timeout 200
--   python tools/rfv_test.py tests/meter_record_test.lua --set project=<path.rpp> --set start=600 --set seconds=120 --set name=second
-- Writes %TEMP%\rfv-live-reads\<name>\reads.csv: one row per tick, "t,pos,L1,R1,L2,R2,..." in
-- track order (t from the first tick, pos the play position), and tracks.txt with the names.
-- The master is muted (not its fader), as in every live test.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")

local args = _G.RFV_ARGS or {}

return {
  name = "meter-record",
  steps = {
    function(tab, ctx)
      local path, name
      if args.project then
        path, name = args.project, args.name or "project"
      else
        name = args.fixture or "band"
        path = L.env().truth .. SEP .. name .. SEP .. name .. ".rpp"
      end
      ctx.name = name
      local start = tonumber(args.start or "0")
      reaper.Main_openProject("noprompt:" .. path)
      ctx.tab = reaper.EnumProjects(-1)
      local P = ctx.tab
      local len = tonumber(args.seconds or "0")
      if len <= 0 then len = reaper.GetProjectLength(P) - start end
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(P), "B_MUTE", 1)
      local n = reaper.CountTracks(P)
      local tr, names = {}, {}
      for i = 0, n - 1 do
        tr[i + 1] = reaper.GetTrack(P, i)
        local _, nm = reaper.GetSetMediaTrackInfo_String(tr[i + 1], "P_NAME", "", false)
        names[i + 1] = nm
      end
      local R = { rows = {}, n = n, names = names }
      _G.RFV_REC = R
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(P, start, false, false)
        reaper.OnPlayButtonEx(P)
        local t0
        local function tick()
          local t = reaper.time_precise()
          t0 = t0 or t
          local pos = reaper.GetPlayPositionEx(P)
          local row = { ("%.6f"):format(t - t0), ("%.6f"):format(pos) }
          for i = 1, n do
            row[#row + 1] = ("%.17g"):format(reaper.Track_GetPeakInfo(tr[i], 0))
            row[#row + 1] = ("%.17g"):format(reaper.Track_GetPeakInfo(tr[i], 1))
          end
          R.rows[#R.rows + 1] = table.concat(row, ",")
          if pos >= start + len - 0.1 or reaper.GetPlayStateEx(P) & 1 == 0 then
            R.done = true
            reaper.OnStopButtonEx(P)
            return
          end
          reaper.defer(tick)
        end
        tick()
      end)
      return nil, ("%s: %d tracks, playing %.0f s from %.0f s"):format(name, n, len, start), len + 3
    end,
    function(tab, ctx)
      local R = _G.RFV_REC
      if not R or not R.done then return false, "playback did not finish" end
      local dir = (os.getenv("TEMP") or "/tmp") .. SEP .. "rfv-live-reads" .. SEP .. ctx.name
      reaper.RecursiveCreateDirectory(dir, 0)
      local f = assert(io.open(dir .. SEP .. "reads.csv", "wb"))
      f:write(table.concat(R.rows, "\n"), "\n")
      f:close()
      f = assert(io.open(dir .. SEP .. "tracks.txt", "wb"))
      f:write(table.concat(R.names, "\n"), "\n")
      f:close()
      -- tick gaps, to compare with the engine's
      local gaps = {}
      local prev
      for _, row in ipairs(R.rows) do
        local t = tonumber(row:match("^([^,]+)"))
        if prev then gaps[#gaps + 1] = t - prev end
        prev = t
      end
      table.sort(gaps)
      return true, ("%d ticks of %d tracks written to %s (tick gap median %.1f ms, p95 %.1f, max %.1f)"):format(#R.rows, R.n, dir,
        1000 * gaps[#gaps // 2 + 1], 1000 * gaps[math.floor(#gaps * 0.95)], 1000 * gaps[#gaps])
    end,
  },
}
