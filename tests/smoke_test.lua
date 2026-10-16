-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 0 gate: the harness runs in a temporary tab, and REAPER loads the engine from the
-- repository through the dev junction in its Scripts folder.

return {
  name = "smoke",
  run = function(tab)
    local SEP = package.config:sub(1, 1)
    local out, pass = {}, true

    local path = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_core.lua"
    local ok, RFV = pcall(dofile, path)
    if ok and type(RFV) == "table" then
      out[#out + 1] = "engine " .. RFV.VERSION .. " loaded from " .. RFV.DIR
    else
      pass = false
      out[#out + 1] = "engine did not load from " .. path .. ": " .. tostring(RFV)
    end

    -- A write lands in the temporary tab, not in the user's.
    reaper.InsertTrackAtIndex(0, false)
    local tr = reaper.GetTrack(tab, 0)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "rfv smoke", true)
    local _, nm = reaper.GetTrackName(tr)
    if nm ~= "rfv smoke" then pass = false end
    out[#out + 1] = ("temp tab write: track name read back '%s', tracks=%d"):format(nm, reaper.CountTracks(tab))

    return pass, table.concat(out, "\n")
  end,
}
