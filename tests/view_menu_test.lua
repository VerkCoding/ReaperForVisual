-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 6 review, U4-b, live: the View menu (engine/rfv_menu.lua) without its popup, which is
-- modal and is tried by hand. What the menu shows (greyed items with a reason, the tick on "Show
-- the whole mix", Undo and Redo only while the engine runs and has something to take back) and
-- what each item does: the view actions through the store, Undo through the running engine.
-- The project's undo, dirty flag and state counter must not move.
-- Tracks: Kick, Snare, Bass.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local SCRIPTS = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(SCRIPTS .. "rfv_store.lua")
local M = dofile(SCRIPTS .. "rfv_menu.lua")

local NONE = "#Show selected tracks (select tracks first)|#Add selected tracks (select tracks first)|#Remove selected tracks (select tracks first)|"
  .. "#Group selected tracks (select tracks first)||Show the whole mix||#Undo view change (nothing to undo)|#Redo view change (nothing to redo)"

-- Undo and dirty are compared across steps; the state counter only within one step, because
-- every bridge command (each step is one) moves it by one with no undo point (measured,
-- 2026-10-13: three empty commands in a row read 280, 281, 282).
local function project_state(P)
  return ("undo=%s dirty=%d"):format(tostring(reaper.Undo_CanUndo2(P)), reaper.IsProjectDirty(P))
end
local function view_of(ctx)
  local doc = S.read(S.sidecar_path(ctx.rpp))
  if not doc then return "-" end
  local by = {}
  for i = 0, reaper.CountTracks(ctx.tab) - 1 do
    local tr = reaper.GetTrack(ctx.tab, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    by[reaper.GetTrackGUID(tr)] = nm
  end
  local names = {}
  for _, g in ipairs(doc.view.tracks) do names[#names + 1] = by[g] or "?" end
  table.sort(names)
  return doc.view.mode .. " " .. table.concat(names, ",")
end

return {
  name = "view-menu",
  cleanup = function(ctx) EL.stop(); if ctx.epath then EL.unregister(ctx.epath) end; _G.RFV_SECTION = nil end,
  steps = {
    function(tab, ctx)
      local sine = L.env().signals .. SEP .. "sine1k_m12.wav"
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
      for _, nm in ipairs({ "Kick", "Snare", "Bass" }) do L.item(L.track(tab, nm, 0), sine, 0, 30) end
      ctx.rpp = H.tmpdir("view-menu") .. SEP .. "vm.rpp"
      local side = S.sidecar_path(ctx.rpp)
      for _, x in ipairs({ side, side .. ".tmp", side .. ".old" }) do os.remove(x) end
      ctx.tab = L.save_reopen(tab, ctx.rpp)
      _G.RFV_SECTION = EL.SECTION -- the menu and the actions talk to the test engine
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_menu")
      EL.run_later(ctx.ecmd)
      ctx.lines, ctx.ok = {}, true
      return nil, "built and saved; engine starting", 2
    end,
    function(tab, ctx)
      local P = ctx.tab
      local function check(what, got, want)
        local good = got == want
        if not good then ctx.ok = false end
        ctx.lines[#ctx.lines + 1] = ("  %-44s %s%s"):format(what, tostring(got), good and "" or ("   <-- FAIL, want " .. tostring(want)))
      end
      ctx.check = check
      local s = M.state(P)
      check("engine seen running", s.engine, true)
      local text, ops = M.build(s)
      check("nothing selected: the menu", text, NONE)
      check("operations behind the items", table.concat(ops, ","), "show,add,remove,group,all,undo,redo")
      for i = 0, reaper.CountTracks(P) - 1 do reaper.SetTrackSelected(reaper.GetTrack(P, i), i < 2) end
      ctx.before = project_state(P) -- selecting moves the state counter; from here nothing may
      check("2 selected: Show is offered", (M.build(M.state(P))):match("^[^|]*"), "Show selected tracks")
      local sc = reaper.GetProjectStateChangeCount(P)
      local ok = M.choose("show", P)
      check("Show selected tracks", ok and view_of(ctx), "chosen Kick,Snare")
      check("... the state counter did not move", reaper.GetProjectStateChangeCount(P) - sc, 0)
      return nil, nil, 0.6
    end,
    function(tab, ctx)
      local P, check = ctx.tab, ctx.check
      local s = M.state(P)
      check("history seen: Undo offered", s.undo >= 1 and (select(1, M.build(s))):match("|Undo view change|") ~= nil, true)
      local sc = reaper.GetProjectStateChangeCount(P)
      check("Show the whole mix", M.choose("all", P) and view_of(ctx), "all Kick,Snare")
      check("... the state counter did not move", reaper.GetProjectStateChangeCount(P) - sc, 0)
      return nil, nil, 0.6
    end,
    function(tab, ctx)
      local P, check = ctx.tab, ctx.check
      local text = M.build(M.state(P))
      check("the whole mix shown: ticked", text:match("|!Show the whole mix|") ~= nil, true)
      check("Undo view change: sent to the engine", (M.choose("undo", P)), true)
      return nil, nil, 0.8
    end,
    function(tab, ctx)
      local P, check = ctx.tab, ctx.check
      check("... the engine undid it", view_of(ctx), "chosen Kick,Snare")
      local s = M.state(P)
      check("Redo offered now", s.redo, 1)
      EL.stop()
      return nil, nil, 1.5
    end,
    function(tab, ctx)
      local P, check = ctx.tab, ctx.check
      local s = M.state(P)
      check("engine stopped: seen", s.engine, false)
      local text = M.build(s)
      check("... Undo greyed with the reason", text:match("|#Undo view change %(start ReaperForVisual first%)|") ~= nil, true)
      local ok, msg = M.choose("undo", P)
      check("... Undo refused", ok, false)
      check("... saying why", msg, "ReaperForVisual is not running: start it to undo or redo")
      check("the project untouched", project_state(P), ctx.before)
      EL.unregister(ctx.epath); ctx.epath = nil
      _G.RFV_SECTION = nil
      return ctx.ok, table.concat(ctx.lines, "\n")
    end,
  },
}
