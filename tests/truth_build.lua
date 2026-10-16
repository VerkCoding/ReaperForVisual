-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Builds a fixture in a temporary tab, saves it as <truth>/<fixture>/<fixture>.rpp (later
-- steps reopen that file to measure it live), then renders the ground-truth stems.
--   python tools/rfv_test.py tests/truth_build.lua --set fixture=calib
-- Then: python tools/truth_stats.py <truth>/<fixture>

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local T = dofile(HERE .. ".." .. SEP .. "tools" .. SEP .. "truth_export.lua")

local args = _G.RFV_ARGS or {}
local name = args.fixture or "calib"

return {
  name = "truth-" .. name,
  steps = {
    function(tab, ctx)
      local info = dofile(HERE .. "fixtures" .. SEP .. name .. ".lua")(tab)
      ctx.dir = L.env().truth .. SEP .. name
      ctx.tab = L.save_reopen(tab, ctx.dir .. SEP .. name .. ".rpp")
      ctx.heard = info.heard or args.heard == "1"
      return nil, ("built '%s': %d tracks, %.0f s, saved to %s"):format(name, reaper.CountTracks(ctx.tab), info.length, ctx.dir)
    end,
    function(tab, ctx)
      return true, T.export(tab, ctx.dir, tonumber(args.srate) or 48000, ctx.heard)
    end,
  },
}
