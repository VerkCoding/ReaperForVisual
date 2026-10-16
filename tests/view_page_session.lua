-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 6, by hand: a session for trying the debug page for real (its clicks reach the engine
-- through REAPER's web interface). Builds the view_commands project in the temporary tab,
-- starts the test engine and plays, holds for --set seconds=120 while someone uses
--   http://127.0.0.1:<port>/rfv/debug.html?section=ReaperForVisual_test
-- then prints the choices the page left beside the project. Not part of the suite.
--   python tools/rfv_test.py tests/view_page_session.lua --set seconds=120 --timeout 30

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")
local args = _G.RFV_ARGS or {}

return {
  name = "view-page-session",
  cleanup = function(ctx) EL.stop(); if ctx.epath then EL.unregister(ctx.epath) end end,
  steps = {
    function(tab, ctx)
      local sine = L.env().signals .. SEP .. "sine1k_m12.wav"
      local st = L.env().signals .. SEP .. "st_500L_3kR.wav"
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      L.track(tab, "Drums", 1)
      L.item(L.track(tab, "Kick", 0, { pan = -0.3 }), sine, 0, 300)
      L.item(L.track(tab, "Snare", -1, { pan = 0.3 }), sine, 0, 300)
      L.item(L.track(tab, "Bass", 0), sine, 0, 300)
      local vox = L.track(tab, "Vox", 0, { pan = 0.5 }); L.item(vox, st, 0, 300)
      local verb = L.track(tab, "Verb", 0)
      L.send(vox, verb, 0.3)
      local lead = L.track(tab, "Lead", 0, { mainsend = false }); L.item(lead, sine, 0, 300)
      local a, b = L.track(tab, "BusA", 0, { pan = -0.8 }), L.track(tab, "BusB", 0, { pan = 0.8 })
      L.send(lead, a, 0.5); L.send(lead, b, 0.5)
      local dir = H.tmpdir("view-page")
      ctx.rpp = dir .. SEP .. "page.rpp"
      ctx.side = S.sidecar_path(ctx.rpp)
      for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, ctx.rpp)
      ctx.proj = ctx.tab
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_page")
      EL.run_later(ctx.ecmd)
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(ctx.proj, 0, false, false)
        reaper.OnPlayButtonEx(ctx.proj)
      end)
      local secs = tonumber(args.seconds or "120")
      return nil, ("ready: open /rfv/debug.html?section=%s for %d s"):format(EL.SECTION, secs), secs
    end,
    function(tab, ctx)
      reaper.OnStopButtonEx(ctx.proj)
      local fh = io.open(ctx.side, "rb")
      local text = fh and fh:read("a") or "(no choices written)"
      if fh then fh:close() end
      local f = EL.read("frame")
      return true, ("last answer: %s (%s)\nchoices beside the project:\n%s"):format(tostring(f and f.ack_msg), tostring(f and f.ack_ok), text)
    end,
  },
}
