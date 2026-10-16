-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- ReaperForVisual action: Show only the tracks selected in REAPER (the chosen tracks become exactly these; groups are kept).
-- Changes only the ReaperForVisual choices (<project>.rfv.json), never the project.

-- Run twice in a row (a held shortcut repeats every ~33 ms), the second run would find the
-- first one still waiting for its last defer and REAPER would ask what to do in a dialog
-- (measured, step 6 review): end that one and run again, without asking.
if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
dofile(HERE .. "rfv_actions.lua").run("show")
reaper.defer(function() end) -- no undo point, even with a change of the user's pending (step 3)
