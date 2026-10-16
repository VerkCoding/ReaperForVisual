-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 4.2: the role classifier against expected tables (tests/roles_expected.lua).
--   1. the styles fixture, built in the temporary tab: API snapshot and .rpp snapshot must give
--      the same roles, and both must match the table;
--   2. four real projects, read as text only: OurGoodWolf, SessionHoangDa, the Tiki Horea
--      template, ForRecord;
--   3. every other project under the projects folder must classify without an error;
--   4. cost on a synthetic project of 228 tracks.
--   python tools/rfv_test.py tests/roles_test.lua [--set projects=<folder>] [--set dump=ogw]
-- (the projects folder: --set projects, else L.env().projects; without one, steps 2-4 are skipped)

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local H = dofile(HERE .. "harness.lua")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local SN = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_snapshot.lua")
local RO = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_roles.lua")
local R = dofile(HERE .. ".." .. SEP .. "tools" .. SEP .. "rfv_rpp.lua")
local EXP = dofile(HERE .. "roles_expected.lua")

local args = _G.RFV_ARGS or {}
local root = args.projects or L.env().projects

local function set_of(t) local s = {}; for _, v in ipairs(t or {}) do s[v] = true end return s end
local function same_set(a, b)
  local x, y = set_of(a), set_of(b)
  for k in pairs(x) do if not y[k] then return false end end
  for k in pairs(y) do if not x[k] then return false end end
  return true
end

local function name_of(snap, k) local s = snap.tracks[k].name; return s ~= "" and s or ("Track " .. k) end

-- One line per track, for reading.
local function dump(snap, res)
  local out = {}
  for k, r in ipairs(res.tracks) do
    out[#out + 1] = ("%3d %-24s %-11s %-18s g=%-3d lv=%d m=%-3d %-18s %s"):format(k, name_of(snap, k):sub(1, 24), r.role, r.kind,
      r.group, r.level, r.members, table.concat(r.flags, ","), r.reason)
  end
  return table.concat(out, "\n")
end

-- Compare a result with an expected table. ix(x) turns a name or an index into an index.
local function check(snap, res, e, ix)
  local bad = {}
  local want_role = {}
  for role, list in pairs(e.roles) do for _, x in ipairs(list) do want_role[ix(x)] = role end end
  local want_flags = {}
  for x, f in pairs(e.flags or {}) do want_flags[ix(x)] = f end
  for k, r in ipairs(res.tracks) do
    local wr = want_role[k] or "source"
    if r.role ~= wr then bad[#bad + 1] = ("%d %s: role %s, expected %s (%s)"):format(k, name_of(snap, k), r.role, wr, r.reason) end
    if not same_set(r.flags, want_flags[k] or {}) then
      bad[#bad + 1] = ("%d %s: flags {%s}, expected {%s}"):format(k, name_of(snap, k), table.concat(r.flags, ","), table.concat(want_flags[k] or {}, ","))
    end
  end
  for x, kind in pairs(e.kinds or {}) do
    local k = ix(x)
    if res.tracks[k].kind ~= kind then bad[#bad + 1] = ("%d %s: kind %s, expected %s"):format(k, name_of(snap, k), res.tracks[k].kind, kind) end
  end
  for x, g in pairs(e.groups or {}) do
    local k, gk = ix(x), (g == 0 and 0 or ix(g))
    if res.tracks[k].group ~= gk then bad[#bad + 1] = ("%d %s: group %d, expected %d"):format(k, name_of(snap, k), res.tracks[k].group, gk) end
  end
  for x, lv in pairs(e.levels or {}) do
    local k = ix(x)
    if res.tracks[k].level ~= lv then bad[#bad + 1] = ("%d %s: level %d, expected %d"):format(k, name_of(snap, k), res.tracks[k].level, lv) end
  end
  local mb = {}
  for _, x in ipairs(e.mixbuses or {}) do mb[#mb + 1] = ix(x) end
  if not same_set(res.mixbuses, mb) then
    bad[#bad + 1] = ("mix buses {%s}, expected {%s}"):format(table.concat(res.mixbuses, ","), table.concat(mb, ","))
  end
  return bad
end

local function counts(res)
  local c, f = {}, {}
  for _, r in ipairs(res.tracks) do
    c[r.role] = (c[r.role] or 0) + 1
    for _, x in ipairs(r.flags) do f[x] = (f[x] or 0) + 1 end
  end
  local s = {}
  for _, role in ipairs({ "source", "bus", "passthrough", "return", "mixbus", "ignored" }) do if c[role] then s[#s + 1] = role .. " " .. c[role] end end
  local fl = {}
  for k, v in pairs(f) do fl[#fl + 1] = k .. " " .. v end
  table.sort(fl)
  return table.concat(s, ", ") .. (#fl > 0 and ("; flags: " .. table.concat(fl, ", ")) or "")
end

local function timed_classify(snap)
  local t0 = reaper.time_precise()
  local res = RO.classify(snap)
  return res, 1000 * (reaper.time_precise() - t0)
end

local steps = {}

-- --set dumpfile=<path.rpp>: print the classification of any project, one line per track.
if args.dumpfile then
  return { name = "roles-dump", steps = { function()
    local snap = assert(R.snapshot_file(args.dumpfile))
    local res = RO.classify(snap)
    return nil, ("%s: %s; mix buses {%s}, %d feeding tracks\n%s"):format(args.dumpfile, counts(res), table.concat(res.mixbuses, ","), res.feeders, dump(snap, res))
  end } }
end

steps[#steps + 1] = function(tab, ctx)
  dofile(HERE .. "fixtures" .. SEP .. "styles.lua")(tab)
  ctx.path = H.tmpdir("roles") .. SEP .. "styles.rpp"
  ctx.tab = L.save_reopen(tab, ctx.path)
  return nil, ("styles built: %d tracks"):format(reaper.CountTracks(ctx.tab))
end

steps[#steps + 1] = function(tab, ctx)
  local api = SN.from_api(tab)
  local res, ms = timed_classify(api)
  local res2 = RO.classify(R.snapshot_file(ctx.path))
  local idx = {}
  for k, t in ipairs(api.tracks) do idx[t.name] = k end
  local function ix(x) if type(x) == "number" then return x end; return idx[x] or error("no track named " .. x) end
  local bad = check(api, res, EXP.styles, ix)
  for k = 1, #res.tracks do
    local a, b = res.tracks[k], res2.tracks[k]
    if a.role ~= b.role or a.group ~= b.group or a.reason ~= b.reason then bad[#bad + 1] = ("%d: API and .rpp snapshots classify differently"):format(k) end
  end
  local line = ("styles: %s; %.2f ms; %s"):format(counts(res), ms, #bad == 0 and "MATCH" or (#bad .. " mismatches"))
  if #bad > 0 or args.dump == "styles" then line = line .. "\n    " .. table.concat(bad, "\n    ") .. "\n" .. dump(api, res) end
  if #bad > 0 then return false, line end
    return nil, line
end

if not root then
  steps[#steps + 1] = function() return nil, "real projects skipped: " .. L.no_path("projects folder", "projects", "RFV_PROJECTS") end
  return { name = "roles", steps = steps }
end

for _, key in ipairs({ "ogw", "hoangda", "tiki", "forrecord" }) do
  local e = EXP[key]
  steps[#steps + 1] = function()
    local path = root .. "/" .. e.file
    local snap, err = R.snapshot_file(path)
    if not snap then return false, key .. ": " .. tostring(err) end
    if #snap.tracks ~= e.n then return false, ("%s: %d tracks, the table was written for %d"):format(key, #snap.tracks, e.n) end
    local res, ms = timed_classify(snap)
    local bad = check(snap, res, e, function(x) return x end)
    local line = ("%s: %s; %.2f ms; %s"):format(key, counts(res), ms, #bad == 0 and "MATCH" or (#bad .. " mismatches"))
    if #bad > 0 then line = line .. "\n    " .. table.concat(bad, "\n    ") end
    if args.dump == key then line = line .. "\n" .. dump(snap, res) end
    if #bad > 0 then return false, line end
    return nil, line
  end
end

-- Spare empty tracks outside the mix bus must not take the mix bus away: OurGoodWolf with ten
-- empty tracks added at the top level keeps PreMaster and its groups.
steps[#steps + 1] = function()
  local snap = R.snapshot_file(root .. "/" .. EXP.ogw.file)
  local function groups(res)
    local g, list = {}, {}
    for _, r in ipairs(res.tracks) do if r.group > 0 and not g[r.group] then g[r.group] = true; list[#list + 1] = r.group end end
    table.sort(list)
    return table.concat(list, ",")
  end
  local before = RO.classify(snap)
  for i = 1, 10 do
    local t = {}
    for k, v in pairs(snap.tracks[#snap.tracks]) do t[k] = v end
    t.guid, t.name, t.audio, t.midi, t.fdepth, t.parent = ("{5PARE%03d-0000-0000-0000-000000000000}"):format(i), "spare " .. i, false, false, 0, 0
    snap.tracks[#snap.tracks + 1] = t
  end
  local after = RO.classify(snap)
  -- the spares themselves are ignored (empty), so they have no group
  local ok = table.concat(after.mixbuses, ",") == "1" and groups(before) == groups(after)
  return ok, ("ogw + 10 spare empty tracks: mix buses {%s} (was {%s}), counted on %s; groups %s (were %s)"):format(
    table.concat(after.mixbuses, ","), table.concat(before.mixbuses, ","), after.basis, groups(after), groups(before))
end

-- Every other project: no error, roles counted.
steps[#steps + 1] = function()
  local done = {}
  for _, e in pairs(EXP) do if e.file then done[(root .. "/" .. e.file):lower()] = true end end
  local files = {}
  local function scan(dir, depth)
    if depth > 3 then return end
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(dir, i); if not f then break end
      if f:lower():match("%.rpp$") and not f:find("mcp%-backup") then files[#files + 1] = dir .. "/" .. f end
      i = i + 1
    end
    i = 0
    while true do
      local d = reaper.EnumerateSubdirectories(dir, i); if not d then break end
      if d ~= "Backups" then scan(dir .. "/" .. d, depth + 1) end
      i = i + 1
    end
  end
  scan(root, 0)
  table.sort(files)
  local lines, failed = {}, false
  for _, path in ipairs(files) do
    if not done[path:lower()] then
      local snap, err = R.snapshot_file(path)
      local ok, res = false, err
      if snap then ok, res = xpcall(RO.classify, debug.traceback, snap) end
      if ok then
        lines[#lines + 1] = ("  %s: %d tracks; %s"):format(path:match("[^/\\]+$"), #snap.tracks, counts(res))
      else
        failed = true
        lines[#lines + 1] = ("  %s: ERROR %s"):format(path:match("[^/\\]+$"), tostring(res))
      end
    end
  end
  if failed then return false, "other projects failed" end
  return nil, ("other projects (%d):\n%s"):format(#lines, table.concat(lines, "\n"))
end

-- Cost: four copies of SessionHoangDa side by side (228 tracks, 208 sends).
steps[#steps + 1] = function()
  local one = R.snapshot_file(root .. "/" .. EXP.hoangda.file)
  local big = { v = one.v, master = one.master, tracks = {}, sends = {} }
  for c = 0, 3 do
    local off = #big.tracks
    for _, t in ipairs(one.tracks) do
      local u = {}
      for k, v in pairs(t) do u[k] = v end
      if u.parent > 0 then u.parent = u.parent + off end
      big.tracks[#big.tracks + 1] = u
    end
    for _, s in ipairs(one.sends) do
      local u = {}
      for k, v in pairs(s) do u[k] = v end
      u.src, u.dst = u.src + off, u.dst + off
      big.sends[#big.sends + 1] = u
    end
  end
  local ms = {}
  for i = 1, 30 do local _, m = timed_classify(big); ms[i] = m end
  table.sort(ms)
  return nil, ("cost: %d tracks, %d sends: classify median %.2f ms, max %.2f ms"):format(#big.tracks, #big.sends, ms[15], ms[30])
end

return { name = "roles", steps = steps }
