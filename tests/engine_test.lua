-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 3, engine behaviour: starts as an action, publishes graph and frames at ~10 Hz,
-- follows the active tab and forgets closed ones, survives an error without a dialog, stops
-- when its action runs again (toolbar state off), and a newer instance replaces an older one.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")

local function names(g) local t = {} for _, x in ipairs(g and g.tracks or {}) do t[#t + 1] = x.name end return table.concat(t, ",") end

return {
  name = "engine",
  steps = {
    -- 1. three tracks, engine started as an action
    function(tab, ctx)
      for i, nm in ipairs({ "Kick", "Bass", "Vox", "" }) do L.track(tab, nm, 0) end  -- the last one unnamed
      -- an engine the user is running, in the real section, must not notice this test
      ctx.user_owner = reaper.GetExtState("ReaperForVisual", "owner")
      local uf = EL.json.decode(reaper.GetExtState("ReaperForVisual", "frame"))
      ctx.user_seq = uf and uf.seq
      ctx.tab = L.save_reopen(tab, H.tmpdir("engine") .. SEP .. "engine.rpp")
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_A")
      EL.run_later(ctx.cmd)
      return nil, "engine A registered as " .. ctx.cmd .. " and started", 1.5
    end,
    -- 2. graph and frames
    function(tab, ctx)
      local g, f = EL.read("graph"), EL.read("frame")
      ctx.seq1, ctx.t1 = f and f.seq, reaper.time_precise()
      local ok = g and f and f.state == "running" and g.tab == tostring(tab) and names(g) == "Kick,Bass,Vox," and #f.a == 4
        and reaper.GetToggleCommandStateEx(0, ctx.cmd) == 1
      return ok, ("running=%s, graph tab is this tab=%s, tracks '%s', frame meters=%d, toolbar on=%s, seq %s"):format(
        tostring(f and f.state), tostring(g and g.tab == tostring(tab)), names(g), f and #f.a or -1,
        tostring(reaper.GetToggleCommandStateEx(0, ctx.cmd) == 1), tostring(f and f.seq)), 1.0
    end,
    -- 3. frame rate; then a second tab
    function(tab, ctx)
      local f = EL.read("frame")
      ctx.rate = (f.seq - ctx.seq1) / (reaper.time_precise() - ctx.t1)
      reaper.Main_OnCommand(40859, 0)
      ctx.tab2 = reaper.EnumProjects(-1)
      L.track(ctx.tab2, "Guitar", 0); L.track(ctx.tab2, "Keys", 0)
      reaper.SelectProjectInstance(tab)  -- the harness expects its own tab active
      return ctx.rate > 7 and ctx.rate < 13, ("frames per second %.1f; opened a second tab with 2 tracks"):format(ctx.rate), 0.3
    end,
    function(tab, ctx)
      reaper.SelectProjectInstance(ctx.tab2)
      ctx.tab_switch = true
      return nil, "second tab selected", 1.0
    end,
    -- 4. the engine follows the active tab, then back
    function(tab, ctx)
      local g = EL.read("graph")
      local on2 = g and g.tab == tostring(ctx.tab2) and names(g) == "Guitar,Keys"
      reaper.SelectProjectInstance(tab)
      return on2, ("graph followed the second tab=%s (tracks '%s')"):format(tostring(on2), names(g)), 1.0
    end,
    function(tab, ctx)
      local g, f = EL.read("graph"), EL.read("frame")
      local back = g and g.tab == tostring(tab) and names(g) == "Kick,Bass,Vox,"
      ctx.tabs_before = f.tabs
      -- close the second tab (make it clean first) and come back
      reaper.SelectProjectInstance(ctx.tab2)
      local p = L.save_reopen(ctx.tab2, H.tmpdir("engine") .. SEP .. "second.rpp")
      reaper.Main_OnCommand(40860, 0)
      reaper.SelectProjectInstance(tab)
      return back, ("back on the first tab=%s; tabs known %d; second tab closed"):format(tostring(back), f.tabs), 6.0
    end,
    -- 5. closed tab forgotten; an injected error does not stop the engine
    function(tab, ctx)
      local f = EL.read("frame")
      local pruned = f.tabs == 1
      reaper.SetExtState(EL.SECTION, "debug_fault", "1", false)
      ctx.seq2 = f.seq
      return pruned, ("tabs known after closing: %d (was %d)"):format(f.tabs, ctx.tabs_before), 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local survived = f.state == "running" and f.seq > ctx.seq2 + 5 and type(f.err) == "string" and f.err:find("injected fault") ~= nil
      EL.run_later(ctx.cmd) -- the same action again: stop
      return survived, ("after an injected error: still running=%s, error reported=%s"):format(
        tostring(f.state == "running" and f.seq > ctx.seq2 + 5), tostring(type(f.err) == "string")), 1.0
    end,
    -- 6. stopped by running the action again
    function(tab, ctx)
      local f = EL.read("frame")
      local stopped = f.state == "stopped" and reaper.GetToggleCommandStateEx(0, ctx.cmd) == 0 and reaper.GetExtState(EL.SECTION, "owner") == ""
      EL.run_later(ctx.cmd) -- start A again
      ctx.cmdB, ctx.pathB = EL.register("rfv_engine_test_B")
      return stopped, ("action run again: state %s (%s), toolbar off=%s, owner cleared=%s"):format(f.state, tostring(f.reason),
        tostring(reaper.GetToggleCommandStateEx(0, ctx.cmd) == 0), tostring(reaper.GetExtState(EL.SECTION, "owner") == "")), 1.0
    end,
    -- 7. a newer instance replaces the older one
    function(tab, ctx)
      local a_on = reaper.GetToggleCommandStateEx(0, ctx.cmd) == 1
      EL.run_later(ctx.cmdB)
      return a_on, "A running again=" .. tostring(a_on) .. "; starting B", 1.0
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local a_off, b_on = reaper.GetToggleCommandStateEx(0, ctx.cmd) == 0, reaper.GetToggleCommandStateEx(0, ctx.cmdB) == 1
      EL.stop()
      return a_off and b_on and f.state == "running", ("B started: A stopped=%s, B running=%s"):format(tostring(a_off), tostring(b_on)), 1.0
    end,
    -- 8. stop on request; clean up
    function(tab, ctx)
      local f = EL.read("frame")
      local b_off = reaper.GetToggleCommandStateEx(0, ctx.cmdB) == 0
      EL.unregister(ctx.path); EL.unregister(ctx.pathB)
      local gone = (reaper.kbd_getTextFromCmd(ctx.cmd, nil) or "") == "" and (reaper.kbd_getTextFromCmd(ctx.cmdB, nil) or "") == ""
      -- a page seen within 10 s keeps the engine from opening another browser tab
      local E = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_engine.lua")
      reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
      local fresh = E.page_recent(EL.SECTION)
      reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000 - 60000), false)
      local old = E.page_recent(EL.SECTION)
      reaper.DeleteExtState(EL.SECTION, "page_seen", false)
      local page_ok = fresh and not old and not E.page_recent(EL.SECTION)
      -- the user's engine, if one runs, kept its owner and kept publishing
      local user_ok, user_note = true, "no user engine running"
      if ctx.user_owner ~= "" then
        local uf = EL.json.decode(reaper.GetExtState("ReaperForVisual", "frame"))
        user_ok = reaper.GetExtState("ReaperForVisual", "owner") == ctx.user_owner and uf and uf.state == "running" and uf.seq > (ctx.user_seq or 0)
        user_note = ("user's engine kept its owner and ran on (seq %s -> %s)=%s"):format(tostring(ctx.user_seq), tostring(uf and uf.seq), tostring(user_ok))
      end
      return f.state == "stopped" and b_off and gone and page_ok and user_ok,
        ("stop request: %s (%s), toolbar off=%s; test actions removed=%s; page check fresh/old/none ok=%s; %s"):format(
        f.state, tostring(f.reason), tostring(b_off), tostring(gone), tostring(page_ok), user_note)
    end,
  },
}
