-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Runs one test inside a fresh temporary project tab, then closes that tab without a save
-- prompt and gives the user's tab back. The user's projects are never written to.
--
-- A test file returns a table:
--   name    = "..."
--   run     = function(tab, ctx) return pass, detail end         -- a one-step test, or
--   steps   = { function(tab, ctx) return pass, detail, wait end, ... }
--   no_tab  = true   -- pure logic: no temporary tab is opened, tab is nil
--   cleanup = function(ctx) ... end  -- run at the end whatever happened (stop an engine,
--                                       unregister launchers)
-- Each step runs in its own bridge command, so a step that changes the temporary project ends
-- with that tab active and its undo point lands there. A step may return `wait` in seconds;
-- tools/rfv_test.py sleeps that long before the next step. ctx is a table kept across steps.
-- pass = false fails the test at once; pass = nil means "no verdict yet".

local H = {}
local SEP = package.config:sub(1, 1)

function H.tmpdir(sub)
  local d = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. SEP .. "rfv-tests"
  if sub then d = d .. SEP .. sub end
  reaper.RecursiveCreateDirectory(d, 0)
  return d
end

-- A dirty tab raises a modal save prompt on close, which freezes every script.
-- Saving a copy leaves the tab dirty; reopening that copy with noprompt makes it clean.
local function close_clean(tab, name)
  reaper.SelectProjectInstance(tab)
  if reaper.GetPlayStateEx(tab) ~= 0 then reaper.OnStopButtonEx(tab) end
  if reaper.IsProjectDirty(tab) ~= 0 then
    local path = H.tmpdir() .. SEP .. name .. ".rpp"
    reaper.Main_SaveProjectEx(tab, path, 0)
    reaper.Main_openProject("noprompt:" .. path)
    tab = reaper.EnumProjects(-1)
  end
  if reaper.IsProjectDirty(tab) ~= 0 then return false, "temp tab still dirty, left open" end
  reaper.Main_OnCommand(40860, 0) -- Close current project tab
  return true
end

-- Deferred code of a test runs inside the bridge's own script, since every bridge command does.
-- An error there raises REAPER's ReaScript error dialog (modal: every script stops) and ends that
-- script, the bridge's listener with it (2026-10-13: a deferred probe of view_actions_test used a
-- tab the harness had already closed; the bridge then had to be started again by hand). So the
-- first test wraps reaper.defer in this Lua state: an error in a deferred callback is caught,
-- kept in _G.RFV_DEFER_ERRORS, and fails the test that was running; that callback chain stops.
-- A test's deferred loops also end when the test ends (step 6 review, 2026-10-13): a sampler
-- that missed its end condition kept running into the next test and stopped that test's
-- playback through a tab pointer that no longer existed. Every test begins and finishes a new
-- generation, and callbacks scheduled in an older one are dropped. The bridge's own listener
-- schedules itself through reaper.defer too, so callbacks defined in claude_bridge.lua are
-- never dropped.
local WRAP = 2
local function guard_defer()
  if _G.RFV_DEFER_WRAP == WRAP then return end
  local raw = _G.RFV_RAW_DEFER or reaper.defer -- an older wrapper is replaced, not wrapped again
  _G.RFV_RAW_DEFER, _G.RFV_DEFER_WRAP = raw, WRAP
  _G.RFV_DEFER_GEN = _G.RFV_DEFER_GEN or 0
  reaper.defer = function(fn)
    local info = debug.getinfo(fn, "S")
    local gen = not (info and info.source:find("claude_bridge", 1, true)) and _G.RFV_DEFER_GEN or nil
    return raw(function()
      if gen and gen ~= _G.RFV_DEFER_GEN then return end -- its test has ended
      local ok, err = xpcall(fn, debug.traceback)
      if not ok then
        _G.RFV_DEFER_ERRORS = _G.RFV_DEFER_ERRORS or {}
        table.insert(_G.RFV_DEFER_ERRORS, tostring(err):sub(1, 500))
      end
    end)
  end
end
local function new_generation() _G.RFV_DEFER_GEN = (_G.RFV_DEFER_GEN or 0) + 1 end

-- Phase 1: remember the user's tab, load the test, open the temporary tab.
function H.begin(test_path)
  guard_defer()
  new_generation() -- loops an earlier test left behind end here
  _G.RFV_DEFER_ERRORS = {}
  local user = reaper.EnumProjects(-1)
  -- Opening a tab while the user listens would interrupt them.
  if reaper.GetPlayStateEx(user) ~= 0 then return "SKIP: the active project is playing or recording; run again when stopped" end
  local test = dofile(test_path)
  local S = { test = test, name = test.name or test_path, user = user, user_dirty = reaper.IsProjectDirty(user),
              steps = test.steps or { test.run }, i = 0, ctx = {}, out = {}, failed = false }
  if not test.no_tab then
    reaper.Main_OnCommand(40859, 0) -- New project tab
    S.tab = reaper.EnumProjects(-1)
    if S.tab == user then return "FAIL harness: no temporary tab opened for " .. S.name end
  end
  _G.RFV_HARNESS = S
  return ("BEGIN %s steps=%d"):format(S.name, #S.steps)
end

-- Phase 2: run the next step. Returns "STEP i/n wait=<s>" or "DONE".
function H.step()
  local S = _G.RFV_HARNESS
  if not S then return "FAIL harness: no test begun" end
  if S.failed or S.i >= #S.steps then return "DONE" end
  S.i = S.i + 1
  if S.tab then
    -- Every step must find its own tab active; something else switching tabs is a failure.
    if reaper.EnumProjects(-1) ~= S.tab then reaper.SelectProjectInstance(S.tab) end
    if reaper.EnumProjects(-1) ~= S.tab then S.failed = true; S.out[#S.out + 1] = "harness: temp tab vanished"; return "DONE" end
    S.tab = reaper.EnumProjects(-1)
  end
  local ok, pass, detail, wait = xpcall(S.steps[S.i], debug.traceback, S.tab, S.ctx)
  if S.ctx.tab then S.tab = S.ctx.tab; S.ctx.tab = nil end -- a step that reopened the tab hands the new pointer back
  if not ok then
    S.failed = true; S.out[#S.out + 1] = ("step %d error: %s"):format(S.i, tostring(pass))
  else
    if detail then S.out[#S.out + 1] = ("step %d: %s"):format(S.i, tostring(detail)) end
    if pass == false then S.failed = true end
  end
  if S.failed or S.i >= #S.steps then return "DONE" end
  return ("STEP %d/%d wait=%s"):format(S.i, #S.steps, tostring(wait or 0))
end

-- Phase 3: close the temporary tab clean, select the user's tab, report.
-- What test engines learned while their projects played (step 9a: kept per project in REAPER's
-- resource folder, under the tests' own section): removed before and after every test. The
-- user's engine keeps its files under its own section, which this never touches.
local function clear_test_learning()
  local sep = package.config:sub(1, 1)
  local dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "ReaperForVisual" .. sep .. "learned" .. sep .. "ReaperForVisual_test"
  local files, i = {}, 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    files[#files + 1] = f
    i = i + 1
  end
  for _, f in ipairs(files) do os.remove(dir .. sep .. f) end
end

function H.finish()
  local S = _G.RFV_HARNESS
  if not S then return "FAIL harness: no test begun" end
  _G.RFV_HARNESS = nil
  new_generation() -- the test's deferred loops end before its tab closes
  -- the test's own cleanup (an engine to stop, launchers to unregister), also when it failed
  if S.test.cleanup then
    local ok, err = pcall(S.test.cleanup, S.ctx)
    if not ok then S.out[#S.out + 1] = "cleanup error: " .. tostring(err) end
  end
  clear_test_learning()
  local closed, why = true, nil
  if S.tab then closed, why = close_clean(S.tab, "rfv-test-" .. S.name:gsub("[^%w_-]", "_")) end
  reaper.SelectProjectInstance(S.user)
  local back = reaper.EnumProjects(-1) == S.user
  local dirty_after = reaper.IsProjectDirty(S.user)
  local derr = _G.RFV_DEFER_ERRORS or {}
  if #derr > 0 then S.failed = true end
  local verdict = S.failed and "FAIL" or (S.i == #S.steps and "PASS" or "FAIL incomplete")
  local lines = { verdict .. " " .. S.name }
  for _, l in ipairs(S.out) do lines[#lines + 1] = l end
  for _, e in ipairs(derr) do lines[#lines + 1] = "error in deferred test code (caught, no dialog): " .. e end
  lines[#lines + 1] = ("harness: temp tab closed=%s%s, user tab active=%s, user dirty %d->%d"):format(
    tostring(closed), why and (" (" .. why .. ")") or "", tostring(back), S.user_dirty, dirty_after)
  if not closed or not back or dirty_after ~= S.user_dirty then lines[1] = "FAIL harness: " .. lines[1] end
  return table.concat(lines, "\n")
end

return H
