-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- ReaperForVisual engine core: version, paths and the module loader. The read-only engine
-- loop is built in roadmap step 3.

local RFV = {}

RFV.VERSION = "0.1.0"
RFV.SEP = package.config:sub(1, 1)

-- Folder this file was loaded from, as REAPER sees it (through the dev junction).
RFV.DIR = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or ""

local loaded = {}

-- RFV.load("rfv_json") loads engine/rfv_json.lua once and returns its module table.
function RFV.load(name)
  if not loaded[name] then loaded[name] = dofile(RFV.DIR .. RFV.SEP .. name .. ".lua") end
  return loaded[name]
end

return RFV
