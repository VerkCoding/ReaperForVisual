-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 10a, the long run: the band fixture (37 tracks, 96 s, REAPER's own FX only, master
-- muted, the whole mix shown, a page counted as open) played in a loop for --set minutes=N (60
-- for the gate), in blocks of --set block=S seconds (300). Each block records the engine's
-- figures (tick and frame cost, Lua memory, the longest tick and gap, the map, errors) and does
-- one thing to it, in turn:
--   a track with an item added; that track deleted; playback stopped for the block (the stage
--   worked out only on change); a second tab opened, shown 20 s, the band shown again and the
--   second tab closed (REAPER plays the active tab: the band's playback stops there, and the next
--   block plays again); playing again.
-- Gate: the engine runs to the end with no error; Lua memory in the last third of the run
-- within 25 % of the middle third's (no leak), tick cost median likewise (no drift): the first
-- third holds the start, while the map and the learning fill up (a 6-minute try: 3.4 -> 4.8 MB);
-- the map's drops only where items changed. Gaps over 0.25 s (REAPER held) are counted.
--   python tools/rfv_test.py tests/endurance_test.lua --set minutes=60 --timeout 4200

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(ENG .. "rfv_store.lua")
local V = dofile(ENG .. "rfv_view.lua")
local EN = dofile(ENG .. "rfv_engine.lua") -- for the learning file's name only
local J = EL.json
local DIR = L.env().truth .. SEP .. "band" .. SEP

local args = _G.RFV_ARGS or {}
local MINUTES = tonumber(args.minutes) or 60
local BLOCK = tonumber(args.block) or 300
local NBLOCKS = math.max(1, math.floor(MINUTES * 60 / BLOCK + 0.5))

local function median(v)
  local s = {}
  for i, x in ipairs(v) do s[i] = x end
  table.sort(s)
  if #s == 0 then return 0 end
  return #s % 2 == 1 and s[(#s + 1) // 2] or (s[#s // 2] + s[#s // 2 + 1]) / 2
end

local function play(P)
  reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(P) end)
end

-- the figures of the moment, kept for the gate and printed as one line
local function record(ctx, label)
  local f = EL.read("frame")
  local c = f and f.cost or {}
  local ym = f and f.ym ~= J.null and f.ym or {}
  local row = { t = reaper.time_precise() - ctx.t0, med = c.ms_med, p95 = c.ms_p95, fmed = c.frame_ms_med, fp95 = c.frame_ms_p95,
                mem = c.mem_kb, maxms = c.max_ms, maxat = c.max_at, maxkind = c.max_kind, gap = c.gap_max_ms, gapat = c.gap_max_at, lg = c.long_gaps,
                wps = ym.wps, resets = ym.resets, learned = ym.learned, err = f and f.err, state = f and f.state, play = f and f.play }
  ctx.rows[#ctx.rows + 1] = row
  return ("%5.0f s %-28s tick %.2f/%.2f ms, frame %.2f/%.2f ms, mem %.0f KB, longest tick %.1f ms at %s s (%s), longest gap %s ms at %s s (%s over 0.25 s), map %s w/s %s drops, learned %s%s"):format(
    row.t, label, row.med or -1, row.p95 or -1, row.fmed or -1, row.fp95 or -1, row.mem or -1, row.maxms or -1, tostring(row.maxat),
    tostring(row.maxkind), tostring(row.gap), tostring(row.gapat), tostring(row.lg), tostring(row.wps), tostring(row.resets), tostring(row.learned),
    (row.err and row.err ~= J.null) and ("  ERROR " .. J.encode(row.err)) or "")
end

-- what each block does, in turn
local ACTIONS = {
  function(ctx)
    local tr = L.track(ctx.tab, "Extra", 0)
    L.item(tr, L.env().signals .. SEP .. "noise_m20.wav", 0, 20)
    ctx.items_changed = (ctx.items_changed or 0) + 1
    return "a track added (Extra)"
  end,
  function(ctx)
    for i = reaper.CountTracks(ctx.tab) - 1, 0, -1 do
      local tr = reaper.GetTrack(ctx.tab, i)
      local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      if nm == "Extra" then reaper.DeleteTrack(tr) end
    end
    return "the track deleted"
  end,
  function(ctx)
    reaper.OnStopButtonEx(ctx.tab)
    return "stopped for a block"
  end,
  function(ctx)
    play(ctx.tab)
    -- a second tab for 20 s, then the band again and the second tab closed (an end that cannot
    -- be missed: the loop stops itself after 60 s whatever happens)
    -- left empty: a tab with a change would ask to be saved when closed (a modal dialog)
    reaper.Main_OnCommand(40859, 0) -- New project tab
    local other = reaper.EnumProjects(-1)
    local t1 = reaper.time_precise()
    local band = ctx.tab
    local function back()
      local dt = reaper.time_precise() - t1
      if ctx.stop or dt > 60 then return end
      if dt >= 20 and not ctx.back_done then
        ctx.back_done = true
        if reaper.ValidatePtr2(0, other, "ReaProject*") then
          reaper.SelectProjectInstance(other)
          reaper.Main_OnCommand(40860, 0) -- Close current project tab (a new, empty one: no prompt)
        end
        if reaper.ValidatePtr2(0, band, "ReaProject*") then reaper.SelectProjectInstance(band) end
        return
      end
      reaper.defer(back)
    end
    ctx.back_done = false
    reaper.defer(back)
    return "a second tab for 20 s, playing"
  end,
  function(ctx)
    if reaper.GetPlayStateEx(ctx.tab) & 1 ~= 1 then play(ctx.tab) end
    return "playing on"
  end,
}

local steps = {
  function(tab, ctx)
    local rpp = DIR .. "band.rpp"
    ctx.side = S.sidecar_path(rpp)
    reaper.Main_openProject("noprompt:" .. rpp)
    ctx.tab = reaper.EnumProjects(-1)
    local _, lf = EN.learn_file(ctx.tab, EL.SECTION)
    ctx.learnfile = lf
    if lf then os.remove(lf) end
    reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(ctx.tab), "B_MUTE", 1)
    reaper.GetSet_LoopTimeRange2(ctx.tab, true, true, 0, 96, false)
    reaper.GetSetRepeatEx(ctx.tab, 1)
    S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end)
    EL.reset()
    ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_endurance")
    EL.run_later(ctx.ecmd)
    reaper.SetEditCurPos2(ctx.tab, 0, false, false)
    ctx.rows, ctx.lines, ctx.t0 = {}, {}, reaper.time_precise()
    -- a page looking all along (an end that cannot be missed: ctx.stop, or the run's length)
    local limit = MINUTES * 60 + 600
    local function seen()
      if ctx.stop or reaper.time_precise() - ctx.t0 > limit then return end
      local t = reaper.time_precise()
      if not ctx.seen_t or t - ctx.seen_t >= 1 then
        ctx.seen_t = t
        reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
      end
      reaper.defer(seen)
    end
    reaper.defer(seen)
    play(ctx.tab)
    return nil, ("band open, engine started, playing in a loop; %d blocks of %d s"):format(NBLOCKS, BLOCK), BLOCK
  end,
}
for b = 1, NBLOCKS do
  steps[#steps + 1] = function(tab, ctx)
    local line = record(ctx, ("block %d"):format(b))
    if b == NBLOCKS then
      ctx.lines[#ctx.lines + 1] = line
      return nil, line, 0.1
    end
    local what = ACTIONS[(b - 1) % #ACTIONS + 1](ctx)
    ctx.lines[#ctx.lines + 1] = line .. "; then " .. what
    return nil, line .. "; then " .. what, BLOCK
  end
end
steps[#steps + 1] = function(tab, ctx)
  ctx.stop = true
  reaper.OnStopButtonEx(ctx.tab)
  local rows = ctx.rows
  local n = #rows
  local third = math.max(1, n // 3)
  local function col(k, a, z) local v = {} for i = a, z do if rows[i][k] then v[#v + 1] = rows[i][k] end end return v end
  local mem1, mem3 = median(col("mem", third + 1, n - third)), median(col("mem", n - third + 1, n))
  local med1, med3 = median(col("med", third + 1, n - third)), median(col("med", n - third + 1, n))
  local errs, down = 0, 0
  for _, r in ipairs(rows) do
    if r.err and r.err ~= J.null then errs = errs + 1 end
    if r.state ~= "running" then down = down + 1 end
  end
  local last = rows[n] or {}
  local memok = mem3 <= mem1 * 1.25
  local costok = med3 <= med1 * 1.25
  local ok = errs == 0 and down == 0 and memok and costok
  EL.stop()
  return ok, table.concat(ctx.lines, "\n") .. "\n" .. ("gate: errors %d, not running %d; Lua memory middle third %.0f KB, last %.0f KB (%s); tick median middle %.2f ms, last %.2f ms (%s); map drops %s (items changed %d times); longest tick %.1f ms at %s s (%s), longest gap %s ms at %s s, %s gaps over 0.25 s"):format(
    errs, down, mem1, mem3, memok and "ok" or "GROWS <-- FAIL", med1, med3, costok and "ok" or "DRIFTS <-- FAIL",
    tostring(last.resets), ctx.items_changed or 0, last.maxms or -1, tostring(last.maxat), tostring(last.maxkind), tostring(last.gap), tostring(last.gapat), tostring(last.lg)), 1.0
end

return {
  name = ("endurance-%d-min"):format(MINUTES),
  cleanup = function(ctx)
    ctx.stop = true
    EL.stop()
    if ctx.epath then EL.unregister(ctx.epath) end
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
    if ctx.learnfile then os.remove(ctx.learnfile); os.remove(ctx.learnfile .. ".tmp") end
  end,
  steps = steps,
}
