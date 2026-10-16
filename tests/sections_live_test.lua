-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 9b, live: the song's sections on the band fixture (four regions; whole mix shown, master
-- muted), against its rendered truth per section.
--   1. Never played: the four sections listed from the regions, each with its average stage, none
--      of it measured there (reported against the truth: the files, FX not known).
--   2. The song played once through, then stopped: each section measured (at least 90 %); every
--      object's heard level and X per section against the truth heard per section. Gate: Z within
--      1.5 dB in median, X within 1 degree.
--   3. Where sections come from, as the page sets it ("sections" command): off, every marker (the
--      band has none), regions again; kept in the graph's view.
-- A page counts as open (page_seen) all along: the engine works sections out only then.
-- python tools/rfv_test.py tests/sections_live_test.lua --timeout 400

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

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return J.decode(s)
end

local function stats(v)
  local s = {}
  for i, x in ipairs(v) do s[i] = math.abs(x) end
  table.sort(s)
  if #s == 0 then return 0, 0, 0 end
  local med = #s % 2 == 1 and s[(#s + 1) // 2] or (s[#s // 2] + s[#s // 2 + 1]) / 2
  return med, s[math.max(1, math.floor(#s * 0.9 + 0.5))], s[#s]
end

-- each object that is its own track (not a sum, not a group) against the truth heard per section
local function judge(ctx)
  local secs, g = EL.read("sections"), EL.read("graph")
  local ez, ex, played, lines = {}, {}, {}, {}
  for _, sec in ipairs(secs and secs.list or {}) do
    played[#played + 1] = ("%s %.0f %%"):format(sec.name, 100 * (sec.played or -1))
    if sec.o and secs.gseq == g.gseq then
      for j, o in ipairs(g.stage.objects) do
        local tt = o.track ~= J.null and ctx.truth.tracks[o.track + 1]
        local t = tt and tt.heard and tt.heard[sec.name]
        local v = sec.o[j]
        local own_track = o.sum == nil or o.sum == J.null -- not the sum of a bus's other tracks
        if t and own_track and t.level_db and t.level_db > -50 and v ~= J.null and v[2] ~= J.null then
          ez[#ez + 1] = v[2] - t.level_db
          if v[1] ~= J.null and t.az_deg then ex[#ex + 1] = v[1] - t.az_deg end
          if math.abs(v[2] - t.level_db) > 2 then lines[#lines + 1] = ("    %s / %s: %+.2f dB"):format(tt.name, sec.name, v[2] - t.level_db) end
        end
      end
    end
  end
  local zm, zp, zx = stats(ez)
  local xm, xp = stats(ex)
  return zm, xm, played, ("Z median %.2f dB, p90 %.2f, max %.2f (n=%d); X median %.2f deg, p90 %.2f (n=%d); measured: %s"):format(
    zm, zp, zx, #ez, xm, xp, #ex, table.concat(played, ", ")) .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or ""), #ez
end

local function send(ctx, obj)
  ctx.seq = (ctx.seq or 5000) + 1
  obj.tab = EL.read("graph").tab
  local body = J.encode(J.object(obj))
  reaper.SetExtState(EL.SECTION, "cmd", ("%d|%d|%s"):format(ctx.seq, #body, body), false)
end

return {
  name = "sections-live",
  cleanup = function(ctx)
    ctx.stop = true
    EL.stop()
    if ctx.epath then EL.unregister(ctx.epath) end
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
    if ctx.learnfile then os.remove(ctx.learnfile); os.remove(ctx.learnfile .. ".tmp") end
  end,
  steps = {
    function(tab, ctx)
      ctx.truth = read_json(DIR .. "truth.json")
      if not ctx.truth then return false, "no truth for band" end
      local rpp = DIR .. "band.rpp"
      ctx.side = S.sidecar_path(rpp)
      reaper.Main_openProject("noprompt:" .. rpp)
      ctx.tab = reaper.EnumProjects(-1)
      local _, lf = EN.learn_file(ctx.tab, EL.SECTION)
      ctx.learnfile = lf
      if lf then os.remove(lf) end
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(ctx.tab), "B_MUTE", 1)
      reaper.GetSetRepeatEx(ctx.tab, 0)
      S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end)
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_sections")
      EL.run_later(ctx.ecmd)
      reaper.SetEditCurPos2(ctx.tab, 0, false, false)
      -- a page looking all along
      local function seen()
        if ctx.stop then return end
        local t = reaper.time_precise()
        if not ctx.seen_t or t - ctx.seen_t >= 1 then
          ctx.seen_t = t
          reaper.SetExtState(EL.SECTION, "page_seen", tostring(os.time() * 1000), false)
        end
        reaper.defer(seen)
      end
      reaper.defer(seen)
      return nil, "band open, engine started; a page counts as open", 45
    end,
    function(tab, ctx)
      local secs = EL.read("sections")
      local names = {}
      for _, x in ipairs(secs and secs.list or {}) do names[#names + 1] = ("%s %g-%g"):format(x.name, x.a, x.b) end
      ctx.listok = secs and secs.used == "regions" and table.concat(names, ", ") == "Verse 2 2-30, Backing vocals 30-60, Shaker 60-78, Ending 78-96"
      ctx.listline = ("sections (%s): %s"):format(secs and secs.used or "?", table.concat(names, ", "))
      local _, _, played, line = judge(ctx)
      ctx.lineA = "never played: " .. line
      local none = true
      for _, x in ipairs(secs and secs.list or {}) do if not x.played or x.played > 0.05 then none = false end end
      ctx.noneok = none
      local P = ctx.tab
      reaper.defer(function() reaper.Main_OnCommand(40101, 0); reaper.OnPlayButtonEx(P) end)
      return nil, ctx.listline .. "\n" .. ctx.lineA .. "\nplaying the song once through", 97.5
    end,
    function(tab, ctx)
      reaper.OnStopButtonEx(ctx.tab)
      return nil, "stopped", 4
    end,
    function(tab, ctx)
      local zm, xm, _, line, n = judge(ctx)
      ctx.nC = n
      local secs = EL.read("sections")
      local all = #(secs and secs.list or {}) == 4
      for _, x in ipairs(secs and secs.list or {}) do if not x.played or x.played < 0.9 then all = false end end
      ctx.zm, ctx.xm, ctx.allok, ctx.lineC = zm, xm, all, "after one play: " .. line
      send(ctx, { op = "sections", source = "off" })
      return nil, ctx.lineC, 3
    end,
    function(tab, ctx)
      local secs, g, f = EL.read("sections"), EL.read("graph"), EL.read("frame")
      ctx.off = #secs.list == 0 and g.view.sections.source == "off" and f.ack_ok == true
      ctx.offmsg = f.ack_msg
      send(ctx, { op = "sections", source = "markers" })
      return nil, ("off: %d sections, the view says %s (%s)"):format(#secs.list, g.view.sections.source, tostring(f.ack_msg)), 3
    end,
    function(tab, ctx)
      local secs, g = EL.read("sections"), EL.read("graph")
      ctx.mk = #secs.list == 0 and g.view.sections.source == "markers" and secs.used == "markers"
      send(ctx, { op = "sections", source = "regions" })
      return nil, ("every marker: %d sections (the band has none)"):format(#secs.list), 3
    end,
    function(tab, ctx)
      local secs, g = EL.read("sections"), EL.read("graph")
      ctx.back = #secs.list == 4 and g.view.sections.source == "regions"
      send(ctx, { op = "sections", source = "chorus" })
      return nil, ("regions again: %d sections"):format(#secs.list), 2
    end,
    function(tab, ctx)
      local f = EL.read("frame")
      local refused = f.ack_ok == false
      ctx.stop = true
      EL.stop()
      local ok = ctx.listok and ctx.noneok and ctx.allok and ctx.nC and ctx.nC >= 20 and ctx.zm <= 1.5 and ctx.xm <= 1.0 and ctx.off and ctx.mk and ctx.back and refused
      return ok, table.concat({
        ctx.listline .. (ctx.listok and "" or "   <-- FAIL"),
        ctx.lineA .. (ctx.noneok and "" or "   <-- FAIL (none should be measured yet)"),
        ctx.lineC .. (ctx.allok and "" or "   <-- FAIL (each measured at least 90 %)"),
        ("gate: Z median %.2f dB (<= 1.5), X median %.2f deg (<= 1)"):format(ctx.zm, ctx.xm),
        ("the source from the page: off %s, every marker %s, regions again %s, an unknown one refused %s (%s)"):format(
          tostring(ctx.off), tostring(ctx.mk), tostring(ctx.back), tostring(refused), tostring(f.ack_msg)),
      }, "\n")
    end,
  },
}
