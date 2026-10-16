-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.1/5.2: engine/rfv_meter.lua against tools/meter_reference.py on the same readings.
-- First: venv/python tools/meter_reference.py --dump %TEMP%/rfv-meter-cases
-- Then:  python tools/rfv_test.py tests/meter_logic_test.lua
-- Every frame's X and Z must agree (1e-6 deg / dB), silence at the same frames, and the decay
-- step measured from the readings must be the emulated 1.4148 dB within its 0.01 dB bin (music that
-- happens to fall by 1.40 dB also lands there; the decay test itself allows 0.02 dB). The decay
-- rate, from whole decays (median of their dB per second), must be the emulated 30 dB/s within
-- 1.5 dB/s where there were enough decays; and the crest grid must give the fitted coefficients
-- at the measured setting.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local MT = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_meter.lua")
local DIR = ((_G.RFV_ARGS or {}).cases) or ((os.getenv("TEMP") or "/tmp") .. SEP .. "rfv-meter-cases")

local function lines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local out = {}
  for l in f:lines() do
    local a, b, c = l:match("^([^,]*),([^,]*),([^,]*)")
    out[#out + 1] = { tonumber(a), tonumber(b), tonumber(c) }
  end
  f:close()
  return out
end

return {
  name = "meter-logic",
  steps = { function()
    local cf = io.open(DIR .. SEP .. "cases.txt", "rb")
    if not cf then return false, "no cases in " .. DIR .. " (run tools/meter_reference.py --dump first)" end
    local out, bad = {}, 0
    for line in cf:lines() do
      local key, name = line:gsub("\r", ""):match("^(%S+)%s+(.*)$")
      local reads, frames = lines(DIR .. SEP .. key .. ".reads.csv"), lines(DIR .. SEP .. key .. ".frames.csv")
      local d, s = MT.new_decay(1.4148, 0.04716), MT.new_track()
      local i, nx, nz, worst_x, worst_z, silence_mismatch = 1, 0, 0, 0, 0, 0
      local t0 = reaper.time_precise()
      for _, f in ipairs(frames) do
        while reads[i] and reads[i][1] <= f[1] + 1e-12 do MT.feed(s, d, reads[i][1], reads[i][2], reads[i][3]); i = i + 1 end
        local x, z = MT.estimate(s, f[1])
        if (z == nil) ~= (f[3] == nil) or (x == nil) ~= (f[2] == nil) then silence_mismatch = silence_mismatch + 1 end
        if x and f[2] then nx = nx + 1; worst_x = math.max(worst_x, math.abs(x - f[2])) end
        if z and f[3] then nz = nz + 1; worst_z = math.max(worst_z, math.abs(z - f[3])) end
      end
      local ms = 1000 * (reaper.time_precise() - t0)
      local rate_ok = not d.rate or math.abs(d.rate - 30) < 1.5
      local ok = silence_mismatch == 0 and worst_x < 1e-6 and worst_z < 1e-6 and math.abs(d.step - 1.4148) < 0.005 and rate_ok
      if not ok then bad = bad + 1 end
      out[#out + 1] = ("%s %-26s %5d readings, %4d frames: X %4d (worst %.1e deg), Z %4d (worst %.1e dB), silence mismatches %d, step %.4f dB (%s), decay %s; %.1f ms%s"):format(
        key, name:sub(1, 26), #reads, #frames, nx, worst_x, nz, worst_z, silence_mismatch, d.step, d.measured and "measured" or "fallback",
        d.rate and ("%.1f dB/s from %d decays"):format(d.rate, #d.rates) or "not measured (too few decays)", ms, ok and "" or "  <-- DIFFERS")
    end
    cf:close()
    local a, b = MT.crest(1.4148, 0.04716)
    local anchor = math.abs(a - MT.CREST_A) < 1e-9 and math.abs(b - MT.CREST_B) < 1e-9
    if not anchor then bad = bad + 1 end
    out[#out + 1] = ("crest grid at the measured setting: %.3f, %.3f (fitted %.3f, %.3f)%s"):format(a, b, MT.CREST_A, MT.CREST_B, anchor and "" or "  <-- DIFFERS")
    return bad == 0 and true or false, table.concat(out, "\n")
  end },
}
