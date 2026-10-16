-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.2, second source: the crest model was fitted on the band fixture; here it meets other
-- recordings, live. Audio files (--set files=a.wav;b.wav, else L.env().second: three stems of
-- another song, SessionHoangDa's, on the owner's computer) are put on tracks with
-- no FX in the temporary tab, from OFFSET seconds into the files, and played for SECONDS with the
-- master at -inf. The engine's frames are written to %TEMP%/rfv-axes-second/frames.json; then
--   venv/python tools/meter_reference.py --judge %TEMP%/rfv-axes-second/frames.json
-- compares each frame's Z with the files' exact power over the same 2 s, and per 20 s section.
--   python tools/rfv_test.py tests/axes_second_test.lua [--set offset=600] [--set seconds=120]

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json

local args = _G.RFV_ARGS or {}
local OFFSET = tonumber(args.offset) or 600
local SECONDS = tonumber(args.seconds) or 120
local FILES = {}
for f in (args.files or L.env().second or ""):gmatch("[^;]+") do
  FILES[#FILES + 1] = f
end

if #FILES == 0 then
  return { name = "axes-second", steps = { function() return nil, "skipped: " .. L.no_path("audio files for this test", "second", "RFV_SECOND") end } }
end

return {
  name = "axes-second",
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      for _, f in ipairs(FILES) do L.item(L.track(tab, f:match("[^/\\]+$")), f, 0, SECONDS, OFFSET) end
      ctx.tab = L.save_reopen(tab, H.tmpdir("axes-second") .. SEP .. "second.rpp")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_second")
      EL.run_later(ctx.cmd)
      _G.RFV_AX2 = { frames = {} }
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(ctx.tab, 0, false, false)
        reaper.OnPlayButtonEx(ctx.tab)
        local last = 0
        local function sample()
          local A = _G.RFV_AX2
          local now = reaper.time_precise()
          if now - last >= 0.1 then
            last = now
            local f = J.decode(reaper.GetExtState(EL.SECTION, "frame"))
            if f and f.play == 1 and f.a then
              A.frames[#A.frames + 1] = J.object{ pos = f.pos, a = f.a }
              A.maxpos, A.t0, A.t1 = math.max(A.maxpos or 0, f.pos), A.t0 or now, now
            end
            A.play, A.pos = f and f.play, f and f.pos
            -- the end: reached, or playback stopped at the project's end between two reads
            if f and ((f.play == 1 and f.pos >= SECONDS - 0.2) or (f.play ~= 1 and (A.maxpos or 0) >= SECONDS - 1)) then
              A.done = true; reaper.OnStopButtonEx(ctx.tab); return
            end
          end
          reaper.defer(sample)
        end
        sample()
      end)
      return nil, ("%d files from %d s, engine started, playing %d s"):format(#FILES, OFFSET, SECONDS), SECONDS + 4
    end,
    function(tab, ctx)
      EL.stop()
      local A = _G.RFV_AX2
      if not A.done then
        return false, ("playback did not reach the end (%d frames over %.1f s of wall time; furthest position %.2f s of %d; last frame play %s at %s)"):format(#A.frames,
          (A.t1 or 0) - (A.t0 or 0), A.maxpos or -1, SECONDS, tostring(A.play), tostring(A.pos))
      end
      local out = H.tmpdir("axes-second") .. SEP .. "frames.json"
      local f = assert(io.open(out, "wb"))
      f:write(J.encode(J.object{ offset = OFFSET, seconds = SECONDS, files = J.array(FILES), frames = J.array(A.frames) }))
      f:close()
      return nil, ("%d frames written to %s"):format(#A.frames, out), 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
