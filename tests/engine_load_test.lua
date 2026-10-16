-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 3, load: the engine on a large project (default 224 tracks, a quarter of them playing
-- audio, master muted), for tools/rfv_watch.py to measure from the outside while it runs.
--   python tools/rfv_test.py tests/engine_load_test.lua --set tracks=224 --set seconds=30
-- and, during the run, in another shell:  python tools/rfv_watch.py --seconds 20
-- --set view=all (step 7): the whole mix is shown, so the engine reads every track's files for Y
-- and width; the frame's "ym" then tells the spectrum map's cost. --set stopped=1 (step 9a):
-- nothing plays, the stage comes from the files at the edit cursor.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")

local args = _G.RFV_ARGS or {}
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local ST = dofile(ENG .. "rfv_store.lua")
local VW = dofile(ENG .. "rfv_view.lua")
local N = tonumber(args.tracks) or 224
local SECONDS = tonumber(args.seconds) or 30

return {
  name = ("engine-load-%d-tracks"):format(N),
  steps = {
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      local S = L.env().signals .. SEP
      local files = { "sine1k_m12.wav", "noise_m20.wav", "st_500L_3kR.wav" }
      for i = 1, N do
        local fd = 0
        if i % 8 == 1 then fd = 1 elseif i % 8 == 0 then fd = -1 end
        local tr = L.track(tab, ("Track %03d"):format(i), fd)
        if i % 4 == 0 then L.item(tr, S .. files[(i // 4) % 3 + 1], 0, 30) end
      end
      reaper.GetSet_LoopTimeRange2(tab, true, true, 0, 30, false)
      reaper.GetSetRepeatEx(tab, 1)
      -- --set regions=N (step 9b): N sections over the 30 s, and a page counted as open, so the
      -- engine works out each section's average stage on its spare ticks
      for r = 1, tonumber(args.regions) or 0 do
        local len = 30 / tonumber(args.regions)
        reaper.AddProjectMarker2(tab, true, (r - 1) * len, r * len, "Part " .. r, -1, 0)
      end
      local rpp = H.tmpdir("load") .. SEP .. "load.rpp"
      local side = ST.sidecar_path(rpp)
      for _, x in ipairs({ side, side .. ".tmp", side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, rpp)
      if args.view == "all" then ST.edit(ctx.tab, {}, function(doc) VW.mode(doc, "all") end) end
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_load")
      EL.run_later(ctx.cmd)
      if args.regions then
        local function seen()
          if ctx.unseen then return end
          reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
          reaper.defer(seen)
        end
        reaper.defer(seen)
      end
      -- --set stopped=1 (step 9a): the engine stays stopped, so every frame works the stage out
      -- from the files at the edit cursor
      if args.stopped ~= "1" then reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(ctx.tab) end) end
      return nil, ("%d tracks, engine started, %s for %d s"):format(reaper.CountTracks(ctx.tab), args.stopped == "1" and "stopped" or "playing", SECONDS), SECONDS
    end,
    -- a structure change while playing: the classifier runs again, warm
    function(tab, ctx)
      local g = EL.read("graph")
      ctx.first = g and g.roles and g.roles.classify_ms
      reaper.CreateTrackSend(reaper.GetTrack(tab, 3), reaper.GetTrack(tab, 9))
      return nil, "added a send", 3.0
    end,
    function(tab, ctx)
      local f, g = EL.read("frame"), EL.read("graph")
      local frame_bytes, graph_bytes = #reaper.GetExtState(EL.SECTION, "frame"), #reaper.GetExtState(EL.SECTION, "graph")
      ctx.gseq = g and g.gseq
      -- Changes that are not structure (faders, here in two separate commands, each of which
      -- moves the state counter) must not rebuild the graph. Wait out the 10 s cost window.
      reaper.SetMediaTrackInfo_Value(reaper.GetTrack(tab, 5), "D_VOL", 0.5)
      return nil, ("graph %d tracks (%d bytes), frame %d meters (%d bytes), %d frames in %.0f s, cost %s; roles %s"):format(
        g and #g.tracks or -1, graph_bytes, f and #f.a or -1, frame_bytes, f and f.seq or 0, f and f.up or 0, f and EL.json.encode(f.cost) or "?",
        g and g.roles and EL.json.encode(g.roles) or "none") .. ("; first classification %.2f ms"):format(ctx.first or -1)
        .. "; spectrum map " .. (f and f.ym and f.ym ~= EL.json.null and EL.json.encode(f.ym) or "not running"), 1.0
    end,
    function(tab, ctx)
      reaper.SetMediaTrackInfo_Value(reaper.GetTrack(tab, 6), "D_VOL", 0.5)
      return nil, "second fader change", 11.0
    end,
    function(tab, ctx)
      local f, g = EL.read("frame"), EL.read("graph")
      reaper.OnStopButtonEx(tab)
      EL.stop()
      local same = g and g.gseq == ctx.gseq
      return same, ("after two fader changes: graph rebuilt=%s (gseq %s -> %s); cost of the last 10 s %s; spectrum map %s"):format(
        tostring(not same), tostring(ctx.gseq), tostring(g and g.gseq), f and EL.json.encode(f.cost) or "?",
        f and f.ym and f.ym ~= EL.json.null and EL.json.encode(f.ym) or "not running"), 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      ctx.unseen = true
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
