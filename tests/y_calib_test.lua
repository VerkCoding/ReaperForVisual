-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 7, live, stopped: the engine's Y and width on the calib fixture (tests/truth_build.lua),
-- whose answers are known by arithmetic, read from the frame while REAPER is stopped (the map
-- reads ahead of the edit cursor). The view is set to the whole mix so every track is needed.
--   a sine panned +0.5: 1 kHz, correlation 1; 500 Hz left and 3 kHz right: their geometric mean,
--   correlation 0; the same panned +0.5: the pan matrix moves Y to the truth's 2,096 Hz; noise
--   against itself inverted: correlation -1 (anti-phase); a virtual instrument: no Y, all of its
--   power unknown; the project is not touched.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(ENG .. "rfv_store.lua")
local V = dofile(ENG .. "rfv_view.lua")
local DIR = (os.getenv("TEMP") or "") .. SEP .. "rfv-truth" .. SEP .. "calib" .. SEP

local function oct(a, b) return (a and b) and math.abs(math.log(a / b, 2)) or math.huge end

return {
  name = "y-calib",
  cleanup = function(ctx)
    EL.stop()
    if ctx.epath then EL.unregister(ctx.epath) end
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
  end,
  steps = {
    function(tab, ctx)
      local rpp = DIR .. "calib.rpp"
      if not reaper.file_exists(rpp) then return false, "no calib fixture: run tests/truth_build.lua --set fixture=calib" end
      ctx.side = S.sidecar_path(rpp)
      for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end
      reaper.Main_openProject("noprompt:" .. rpp)
      ctx.tab = reaper.EnumProjects(-1)
      reaper.SetEditCurPos2(ctx.tab, 0.5, false, false)
      S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end)
      ctx.before = { reaper.IsProjectDirty(ctx.tab), tostring(reaper.Undo_CanUndo2(ctx.tab)) }
      EL.reset()
      ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_ycalib")
      EL.run_later(ctx.ecmd)
      return nil, "calib opened, the whole mix shown, engine starting (stopped at 0.5 s)", 3
    end,
    function(tab, ctx)
      local f, g = EL.read("frame"), EL.read("graph")
      if not f or not g or not f.y then return false, "no frame with y from the engine: " .. tostring(reaper.GetExtState(EL.SECTION, "error")) end
      local by = {}
      for i, t in ipairs(g.tracks) do by[t.name] = f.y[i] end
      local out, bad = {}, 0
      local function check(what, ok, detail)
        if not ok then bad = bad + 1 end
        out[#out + 1] = ("  %-36s %s%s"):format(what, detail, ok and "" or "   <-- FAIL")
      end
      local function show(v)
        if v == nil or v == J.null then return "null" end
        local y = v[1] ~= J.null and ("%.0f Hz"):format(v[1]) or "no Y"
        local c = v[2] ~= J.null and ("corr %.3f"):format(v[2]) or "no corr"
        return ("%s, %s, unknown %.2f, unseen FX %.2f, read %.2f"):format(y, c, v[3], v[4], v[5])
      end
      local function yv(v) return v and v ~= J.null and v[1] ~= J.null and v[1] or nil end
      local function cv(v) return v and v ~= J.null and v[2] ~= J.null and v[2] or nil end
      local a = by["sine pan +0.5"]
      check("sine pan +0.5", oct(yv(a), 1000) < 0.02 and math.abs((cv(a) or 0) - 1) < 0.01, show(a))
      local b = by["st 500L 3kR"]
      check("500 Hz left, 3 kHz right", oct(yv(b), 1224.7) < 0.03 and math.abs(cv(b) or 9) < 0.03, show(b))
      local c = by["st pan +0.5"]
      check("the same panned +0.5 (truth 2,096 Hz)", oct(yv(c), 2096.7) < 0.05, show(c))
      local d = by["noise anti-phase"]
      check("noise anti-phase", math.abs((cv(d) or 0) + 1) < 0.01, show(d))
      local e = by["sine stereo -0.702 w0.3"]
      check("sine, stereo pan with width 0.3", math.abs((cv(e) or 0) - 1) < 0.01, show(e))
      local s = by["synth chord"]
      check("virtual instrument: no Y, all unknown", s ~= nil and s ~= J.null and s[1] == J.null and s[3] == 1, show(s))
      check("the map's state in the frame", f.ym ~= nil and f.ym ~= J.null, f.ym and f.ym ~= J.null and
        ("%d tracks, around the cursor %.2f read, the song %.2f, %.2f ms last tick, %d windows"):format(f.ym.tracks, f.ym.now, f.ym.song, f.ym.ms, f.ym.windows) or "none")
      local after = { reaper.IsProjectDirty(tab), tostring(reaper.Undo_CanUndo2(tab)) }
      check("the project untouched", after[1] == ctx.before[1] and after[2] == ctx.before[2], ("dirty %d, undo %s"):format(after[1], after[2]))
      -- the chosen tracks only: one chosen track, and Y is worked out for that one alone (the map
      -- reads it first; since step 9a it then reads the others too, for the mix when stopped)
      local anti
      for _, t in ipairs(g.tracks) do if t.name == "noise anti-phase" then anti = t.guid end end
      S.edit(tab, {}, function(doc) V.show(doc, { anti }) end)
      ctx.out, ctx.check, ctx.show = out, check, show
      ctx.bad = function() return bad end -- check() counts into this step's local
      -- a change made by another program is followed within a second, then the stage and Y
      return nil, nil, 3
    end,
    function(tab, ctx)
      local f, g = EL.read("frame"), EL.read("graph")
      local others = 0
      for i, t in ipairs(g.tracks) do
        if t.name ~= "noise anti-phase" and f.y[i] ~= J.null then others = others + 1 end
      end
      local a
      for i, t in ipairs(g.tracks) do if t.name == "noise anti-phase" then a = f.y[i] end end
      ctx.check("one track chosen: Y for it alone", f.ym ~= J.null and f.ym.tracks == 1 and others == 0,
        ("%s tracks needed, %d others with a Y; the engine's view: %s, %d object(s) on the stage"):format(f.ym ~= J.null and f.ym.tracks or "?", others,
          g.view ~= J.null and (g.view.mode .. " " .. #g.view.tracks) or "none", #g.stage.objects))
      ctx.check("... and it is ready at once", a ~= nil and a ~= J.null and math.abs((a[2] ~= J.null and a[2] or 0) + 1) < 0.01, ctx.show(a))
      EL.stop()
      return ctx.bad() == 0, table.concat(ctx.out, "\n")
    end,
  },
}
