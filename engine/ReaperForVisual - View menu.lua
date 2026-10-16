-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- ReaperForVisual action: every view action in one menu where the mouse is (Show, Add, Remove,
-- Group selected tracks, Show the whole mix, Undo and Redo of view changes). Put this one action
-- on a key, or in a menu or on a toolbar of your own: see the README.
-- Changes only the ReaperForVisual choices (<project>.rfv.json), never the project.

-- Run twice in a row, the second run would find the first one still waiting for its last defer
-- and REAPER would ask what to do in a dialog (measured, step 6 review): end that one and run
-- again, without asking.
if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
dofile(HERE .. "rfv_menu.lua").run()
reaper.defer(function() end) -- no undo point, even with a change of the user's pending (step 3)
