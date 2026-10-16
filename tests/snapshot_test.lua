-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 4.1: the routing snapshot read through the API and read from the .rpp text agree.
--   1. the "styles" fixture is built in the temporary tab, saved, and both snapshots compared;
--   2. the ground-truth fixtures (calib, band, nest; tests/truth_build.lua) are opened in the
--      temporary tab, if present, and compared the same way;
--   3. the owner's real projects are only read as text (they hold third-party plugins, and a
--      licence dialog would freeze REAPER), one per step: they must parse, and the cost is
--      reported.
--   python tools/rfv_test.py tests/snapshot_test.lua [--set projects=<folder>]
-- (the projects folder: --set projects, else L.env().projects; without one, step 3 is skipped)

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local SN = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_snapshot.lua")
local R = dofile(HERE .. ".." .. SEP .. "tools" .. SEP .. "rfv_rpp.lua")

local args = _G.RFV_ARGS or {}

local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

-- Both producers on one saved, open tab. Also checks the API read changed nothing.
local function compare(tab, path, label)
  local sc0, d0 = reaper.GetProjectStateChangeCount(tab), reaper.IsProjectDirty(tab)
  local t0 = reaper.time_precise()
  local api = SN.from_api(tab)
  local t1 = reaper.time_precise()
  local rpp, err = R.snapshot_file(path)
  local t2 = reaper.time_precise()
  if not rpp then return false, label .. ": .rpp not read: " .. tostring(err) end
  local diffs = SN.diff(api, rpp)
  local touched = reaper.GetProjectStateChangeCount(tab) ~= sc0 or reaper.IsProjectDirty(tab) ~= d0
  local line = ("%s: %d tracks, %d sends; api %.2f ms, rpp %.1f ms; %s%s"):format(label, #api.tracks, #api.sends,
    1000 * (t1 - t0), 1000 * (t2 - t1), #diffs == 0 and "AGREE" or (#diffs .. " differences"),
    touched and "; API READ CHANGED THE PROJECT" or "")
  if #diffs > 0 then line = line .. "\n    " .. table.concat(diffs, "\n    ") end
  return #diffs == 0 and not touched, line
end

local steps = {}

steps[#steps + 1] = function(tab, ctx)
  dofile(HERE .. "fixtures" .. SEP .. "styles.lua")(tab)
  ctx.path = H.tmpdir("snapshot") .. SEP .. "styles.rpp"
  ctx.tab = L.save_reopen(tab, ctx.path)
  return nil, ("styles built: %d tracks, saved to %s"):format(reaper.CountTracks(ctx.tab), ctx.path)
end
steps[#steps + 1] = function(tab, ctx) return compare(tab, ctx.path, "styles") end

for _, name in ipairs({ "calib", "band", "nest" }) do
  local path = L.env().truth .. SEP .. name .. SEP .. name .. ".rpp"
  steps[#steps + 1] = function(tab, ctx)
    if not exists(path) then return nil, name .. ": no truth fixture, skipped (tests/truth_build.lua)" end
    reaper.Main_openProject("noprompt:" .. path)
    ctx.tab = reaper.EnumProjects(-1)
    return compare(ctx.tab, path, name)
  end
end

-- Real projects: text only, never opened.
local root = args.projects or L.env().projects
local files = {}
local function scan(dir, depth)
  if depth > 3 then return end
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():match("%.rpp$") and not f:find("mcp%-backup") then files[#files + 1] = dir .. "/" .. f end
    i = i + 1
  end
  i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    if d ~= "Backups" then scan(dir .. "/" .. d, depth + 1) end
    i = i + 1
  end
end
if root then scan(root, 0) end
table.sort(files)
for _, path in ipairs(files) do
  steps[#steps + 1] = function()
    local t0 = reaper.time_precise()
    local snap, err = R.snapshot_file(path)
    local ms = 1000 * (reaper.time_precise() - t0)
    if not snap then return false, path .. ": " .. tostring(err) end
    local f = io.open(path, "rb"); local size = f:seek("end"); f:close()
    local folders, mainoff, armed, instr, items = 0, 0, 0, 0, 0
    for _, t in ipairs(snap.tracks) do
      if t.fdepth == 1 then folders = folders + 1 end
      if not t.main then mainoff = mainoff + 1 end
      if t.arm then armed = armed + 1 end
      if t.instr then instr = instr + 1 end
      if t.audio or t.midi then items = items + 1 end
    end
    local bad = false
    for _, t in ipairs(snap.tracks) do if not t.guid:match("^{%x+%-%x+%-%x+%-%x+%-%x+}$") then bad = true end end
    for _, s in ipairs(snap.sends) do if s.src < 1 or s.src > #snap.tracks then bad = true end end
    -- Files saved before REAPER 7 may hold no MASTER_TRACKID; the classifier does not need it.
    local note = snap.master.guid == "" and "; no master GUID in the file" or ""
    return not bad and nil, ("%s: %d tracks, %d sends, %d folders, %d master send off, %d armed, %d instruments, %d with items; %.1f MB in %.0f ms%s%s"):format(
      path:match("[^/\\]+$"), #snap.tracks, #snap.sends, folders, mainoff, armed, instr, items, size / 1048576, ms, note,
      bad and " -- BAD GUID OR SEND INDEX" or "")
  end
end
if #files == 0 then
  steps[#steps + 1] = function()
    return nil, root and ("no real projects under " .. root) or ("real projects skipped: " .. L.no_path("projects folder", "projects", "RFV_PROJECTS"))
  end
end

return { name = "snapshot", steps = steps }
