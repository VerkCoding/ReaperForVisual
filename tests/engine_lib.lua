-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Helpers for engine tests. A test registers its own launcher (a copy in the temp folder,
-- never the user's ReaperForVisual action), starts it the way a user would (as an action,
-- from a deferred callback so no bridge undo block is open), and unregisters it afterwards.

local SEP = package.config:sub(1, 1)
local ENGINE = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local J = dofile(ENGINE .. "rfv_json.lua")

local EL = {}
-- Tests write to their own section, so an engine the user is running is never touched.
EL.SECTION = "ReaperForVisual_test"

local function dir()
  local d = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. SEP .. "rfv-tests" .. SEP .. "launchers"
  reaper.RecursiveCreateDirectory(d, 0)
  return d
end

-- Write and register launcher `name`; returns its command ID and path. light: the command whose
-- toolbar light the test engine keeps in step with "all" (default none: a test engine never
-- touches the light of the user's "Show all or chosen tracks" action).
function EL.register(name, light)
  local path = dir() .. SEP .. name .. ".lua"
  local f = assert(io.open(path, "wb"))
  f:write(("dofile([[%srfv_engine.lua]]).run({ open_browser = false, section = %q, light = %s })\n"):format(ENGINE, EL.SECTION,
    light and tostring(math.floor(light)) or "false"))
  f:close()
  return reaper.AddRemoveReaScript(true, 0, path, true), path
end

function EL.unregister(path) return reaper.AddRemoveReaScript(false, 0, path, true) end

-- Run an action after the current bridge command has ended, and after an engine an earlier
-- test left running has stopped: EL.reset() takes its owner token away, so it stops on its next
-- tick; started before that, the action would only toggle the old instance off
-- (set_action_options 1 ends a running instance), and no engine would run (2026-10-13).
function EL.run_later(cmd)
  local t0 = reaper.time_precise()
  local function go()
    if reaper.time_precise() - t0 < 0.2 then reaper.defer(go); return end
    reaper.Main_OnCommand(cmd, 0)
  end
  reaper.defer(go)
end

function EL.stop() reaper.SetExtState(EL.SECTION, "command", "stop", false) end

function EL.read(key)
  local s = reaper.GetExtState(EL.SECTION, key)
  if s == "" then return nil end
  return J.decode(s)
end

-- Clear what a previous run left, so a test reads only its own engine.
function EL.reset()
  for _, k in ipairs({ "frame", "graph", "owner", "command", "error", "debug_fault", "page_seen", "page_sect", "gseq_last", "cmd", "ping", "all_cmd", "sections" }) do
    reaper.DeleteExtState(EL.SECTION, k, false)
  end
end

EL.json = J
return EL
