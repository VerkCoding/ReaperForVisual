-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- ReaperForVisual - Start or stop: run this action to start the engine and open the page; run
-- it again to stop it. Its toolbar button lights while the engine runs. Read only: the project is
-- never changed. (Named "ReaperForVisual.lua" until release 0.1: the name says what it does.)

local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
dofile(dir .. "rfv_engine.lua").run({ open_browser = true })
