-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Steps 5.2 and 5.3: X and Z from the running engine against the rendered ground truth, per
-- section: each track's own output (layer "own"), and where it is heard after its buses (X
-- against the track rendered alone through them, layer "heard"; Z against its share of the mix,
-- "share" from tools/truth_share.py). Heard X counts every track; tracks under a bus flagged for
-- an image gap (its output's image is not its tracks' sum: FX such as a widener, or correlated
-- tracks such as room mics) are also shown apart.
--   python tools/rfv_test.py tests/axes_live_test.lua [--set fixture=band] --timeout 180
-- The fixture's saved project (tests/truth_build.lua) is opened in the temporary tab and played
-- once from the start with the master muted (its fader stays at 0 dB, as when the truth was
-- rendered: heard levels go through it); the test samples the engine's frames every 0.1 s.
-- Per section, as tools/meter_reference.py does: frames from 2 s after the section starts (the
-- Z window), Z averaged as power (a silent frame counts as nothing), X from the powers.
-- Gate (owner, 2026-10-11): X <= 1 deg and Z <= 1.5 dB, median over track-sections.
-- --set relative=1 (for synthetic fixtures such as nest, all steady sines, whose crest is not
-- music's): heard Z is judged as the change from own to heard against the truth's change.
-- Step 7: the view is set to the whole mix (a .rfv.json beside the fixture, removed after), so
-- the engine reads every track's files; Y and width are judged per section against the truth's
-- centroid and correlation (own). Gate (roadmap): Y <= 0.25 octave median where there are audio
-- items; a virtual instrument has no Y.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json
local ENG = reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP
local S = dofile(ENG .. "rfv_store.lua")
local V = dofile(ENG .. "rfv_view.lua")

local args = _G.RFV_ARGS or {}
local NAME = args.fixture or "band"
local Z_WIN = 2.0
local T30 = math.tan(math.rad(30))

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return J.decode(s)
end

local function median(t)
  if #t == 0 then return 0 end
  local s = {}
  for i, v in ipairs(t) do s[i] = math.abs(v) end
  table.sort(s)
  return #s % 2 == 1 and s[(#s + 1) // 2] or (s[#s // 2] + s[#s // 2 + 1]) / 2
end
local function pct(t, p)
  local s = {}
  for i, v in ipairs(t) do s[i] = math.abs(v) end
  table.sort(s)
  return s[math.max(1, math.min(#s, math.floor(#s * p + 0.5)))] or 0
end

return {
  name = "axes-live-" .. NAME,
  cleanup = function(ctx)
    EL.stop()
    if ctx.side then for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old" }) do os.remove(x) end end
  end,
  steps = {
    function(tab, ctx)
      local dir = L.env().truth .. SEP .. NAME
      ctx.truth = read_json(dir .. SEP .. "truth.json")
      ctx.st = read_json(dir .. SEP .. "structure.json")
      if not ctx.truth then return false, "no truth for " .. NAME .. " (tests/truth_build.lua, tools/truth_stats.py)" end
      -- --set reuse=1: judge the frames of the last run again (kept in the bridge's Lua state)
      local A = _G.RFV_AX
      if args.reuse == "1" and A and A.done and A.name == NAME then ctx.reused = true; return nil, ("reusing %d frames of the last run"):format(#A.frames) end
      reaper.Main_openProject("noprompt:" .. dir .. SEP .. NAME .. ".rpp")
      ctx.tab = reaper.EnumProjects(-1)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(ctx.tab), "B_MUTE", 1)
      ctx.side = S.sidecar_path(dir .. SEP .. NAME .. ".rpp")
      S.edit(ctx.tab, {}, function(doc) V.mode(doc, "all") end) -- every track's files are read
      EL.reset()
      ctx.cmd, ctx.path = EL.register("rfv_engine_test_axes")
      EL.run_later(ctx.cmd)
      _G.RFV_AX = { frames = {}, name = NAME }
      local length = ctx.st.length
      reaper.defer(function()
        reaper.Main_OnCommand(40101, 0)
        reaper.SetEditCurPos2(ctx.tab, 0, false, false)
        reaper.OnPlayButtonEx(ctx.tab)
        local last = 0
        local function sample()
          local A = _G.RFV_AX
          local now = reaper.time_precise()
          if now - last >= 0.1 then
            last = now
            local f = J.decode(reaper.GetExtState(EL.SECTION, "frame"))
            if f and f.play == 1 and f.a then
              A.frames[#A.frames + 1] = { pos = f.pos, a = f.a, h = f.h, hi = f.hi, md = f.md, y = f.y, ym = f.ym }
              A.maxpos, A.t0, A.t1 = math.max(A.maxpos or 0, f.pos), A.t0 or now, now
            end
            A.play, A.pos = f and f.play, f and f.pos
            -- the end: reached, or playback stopped at the project's end between two reads
            if f and ((f.play == 1 and f.pos >= length - 0.2) or (f.play ~= 1 and (A.maxpos or 0) >= length - 1)) then
              A.done = true; reaper.OnStopButtonEx(ctx.tab); return
            end
          end
          reaper.defer(sample)
        end
        sample()
      end)
      return nil, ("%s opened (%d tracks, %d s), engine started, playing once"):format(NAME, reaper.CountTracks(ctx.tab), length), length + 4
    end,
    function(tab, ctx)
      if not ctx.reused then EL.stop() end
      local A = _G.RFV_AX
      if not A.done then
        return false, ("playback did not reach the end (%d frames over %.1f s of wall time; furthest position %.2f s of %.1f; last frame play %s at %s)"):format(#A.frames,
          (A.t1 or 0) - (A.t0 or 0), A.maxpos or -1, ctx.st.length, tostring(A.play), tostring(A.pos))
      end
      local secs = { { "all", 0, ctx.st.length } }
      for _, r in ipairs(ctx.st.regions) do secs[#secs + 1] = { r.name, r.start, r["end"] } end
      local ex, ez, rows = {}, {}, {}
      local exb, ezb = {}, {}
      local hx, hz, hflag, hxu = {}, {}, 0, {}
      local idx = {}
      for k, t in ipairs(ctx.st.tracks) do idx[t.guid] = k end
      -- one section's X and Z from a frame field ("a" own, "h" heard), as power-weighted means
      local function judge_field(field, ti, sec)
        local pw, n, L_, R_, flagged = 0, 0, 0, 0, false
        local parent = ctx.st.tracks[ti].parent
        local pk = parent ~= J.null and parent and idx[parent]
        for _, f in ipairs(A.frames) do
          if f.pos >= sec[2] + Z_WIN and f.pos < sec[3] then
            n = n + 1
            local arr = f[field]
            local v = arr and arr[ti]
            if field == "h" and pk then for _, b in ipairs(f.hi or {}) do if b + 1 == pk then flagged = true end end end
            if v and v ~= J.null and v[2] ~= J.null then
              local w = 10 ^ (v[2] / 10)
              pw = pw + w
              if v[1] ~= J.null then
                local q = math.tan(math.rad(v[1])) / T30
                local l, r = (1 - q) / 2, (1 + q) / 2
                L_, R_ = L_ + w * l * l / (l * l + r * r), R_ + w * r * r / (l * l + r * r)
              end
            end
          end
        end
        if n == 0 then return nil end
        local z = pw > 0 and 10 * math.log(pw / n, 10) or -200
        local x
        if L_ + R_ > 0 then local a, b = math.sqrt(L_), math.sqrt(R_); x = math.deg(math.atan((b - a) / (a + b) * T30)) end
        return x, z, flagged
      end
      for ti, tt in ipairs(ctx.truth.tracks) do
        local bus = ctx.st.tracks[ti].folderdepth == 1
        for _, sec in ipairs(secs) do
          local tv = tt.own[sec[1]]
          if type(tv) == "table" and type(tv.level_db) == "number" and tv.level_db >= -70 then
            local x, z = judge_field("a", ti, sec)
            if z then
              local dz, dx = z - tv.level_db, x and (x - tv.az_deg) or nil
              ez[#ez + 1] = dz
              if bus then ezb[#ezb + 1] = dz end
              if dx then ex[#ex + 1] = dx; if bus then exb[#exb + 1] = dx end end
              rows[#rows + 1] = { name = tt.name, sec = sec[1], dz = dz, dx = dx or 0, z = z, truth = tv.level_db }
            end
          end
          local sh = type(tt.share) == "table" and tt.share[sec[1]]
          local hd = type(tt.heard) == "table" and tt.heard[sec[1]]
          if type(sh) == "table" and sh.level_db >= -70 then
            local x, z, flagged = judge_field("h", ti, sec)
            local _, zo = judge_field("a", ti, sec)
            local ov = tt.own[sec[1]]
            if z then
              if args.relative == "1" then
                if zo and type(ov) == "table" then hz[#hz + 1] = (z - zo) - (sh.level_db - ov.level_db) end
              else
                hz[#hz + 1] = z - sh.level_db
              end
              local ax = (type(hd) == "table" and hd.az_deg) or sh.az_deg
              if x then
                hx[#hx + 1] = x - ax
                if flagged then hflag = hflag + 1 else hxu[#hxu + 1] = x - ax end
              end
            end
          end
        end
      end
      -- Y and width (step 7): per section the median reading, against the truth (own)
      local ey, eyf, eyb, eyr, ec, ecf, nq, nvst, nmiss, yrows = {}, {}, {}, {}, {}, {}, 0, 0, 0, {}
      local cover, ncover, wps, ms = 0, 0, 0, 0
      for _, f in ipairs(A.frames) do
        if f.ym and f.ym ~= J.null then cover, ncover, wps, ms = cover + f.ym.now, ncover + 1, wps + (f.ym.wps or 0), ms + f.ym.ms end
      end
      for ti, tt in ipairs(ctx.truth.tracks) do
        local stt = ctx.st.tracks[ti]
        local bus = stt.folderdepth == 1
        local files = (stt.audio_items or 0) > 0
        local vsti = not files and (stt.midi_items or 0) > 0
        if vsti then nvst = nvst + 1 end
        for _, sec in ipairs(secs) do
          local tv = tt.own[sec[1]]
          if type(tv) == "table" and type(tv.centroid_hz) == "number" and tv.level_db >= -70 then
            local ys, cs, u, fx, seen, cvr = {}, {}, 0, 0, 0, 0
            for _, f in ipairs(A.frames) do
              local v = f.y and f.y[ti]
              if f.pos >= sec[2] + Z_WIN and f.pos < sec[3] and v and v ~= J.null then
                seen = seen + 1
                u, fx, cvr = u + v[3], fx + v[4], cvr + v[5]
                if v[1] ~= J.null then ys[#ys + 1] = math.log(v[1], 2) end
                if v[2] ~= J.null then cs[#cs + 1] = v[2] end
              end
            end
            if seen > 0 then
              u, fx = u / seen, fx / seen
              local function med(x) table.sort(x); return #x > 0 and x[(#x + 1) // 2] or nil end
              local ly, c = med(ys), med(cs)
              if u >= 0.5 then
                if vsti then nq = nq + 1 elseif files then nmiss = nmiss + 1; ctx.missing = (ctx.missing or "") .. (" %s/%s (unknown %.2f, read %.2f, %d frames)"):format(tt.name, sec[1], u, cvr / seen, seen) end -- no Y: "?" (right only for an instrument)
              elseif ly then
                local d = ly - math.log(tv.centroid_hz, 2)
                if bus then eyb[#eyb + 1] = d
                elseif not files then eyr[#eyr + 1] = d -- a return: estimated from its sends
                elseif fx >= 0.5 then eyf[#eyf + 1] = d else ey[#ey + 1] = d end
                yrows[#yrows + 1] = { name = tt.name, sec = sec[1], d = d, y = 2 ^ ly, truth = tv.centroid_hz, fx = fx }
                if c and type(tv.corr) == "number" then
                  if fx >= 0.5 then ecf[#ecf + 1] = c - tv.corr else ec[#ec + 1] = c - tv.corr end
                end
              end
            end
          end
        end
      end
      local ysrc = {}
      for _, v in ipairs(ey) do ysrc[#ysrc + 1] = v end
      for _, v in ipairs(eyf) do ysrc[#ysrc + 1] = v end
      table.sort(yrows, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
      local yworst = {}
      for i = 1, math.min(5, #yrows) do
        local r = yrows[i]
        yworst[#yworst + 1] = ("    %s / %s: Y %.0f Hz vs truth %.0f (%+.2f oct)%s"):format(r.name, r.sec, r.y, r.truth, r.d, r.fx >= 0.5 and ", before its FX" or "")
      end
      -- a few sparse parts may have no Y yet while a dense project plays (the map reads about
      -- half the window behind the play position for 36 tracks: step 10b review R2, kept): at
      -- most 3 % of the track-sections with files, one at least
      local allow = math.max(1, math.floor(#ysrc * 0.03))
      ctx.y_ok = (#ysrc == 0 or median(ysrc) <= 0.25) and nmiss <= allow
      if ctx.missing then yworst[#yworst + 1] = ("    files but no Y (%d allowed):"):format(allow) .. ctx.missing end
      ctx.ytext = ("\n  Y (tracks with files): median %.3f oct, p90 %.3f, max %.3f (n=%d); without track FX median %.3f (n=%d), before their FX %.3f (n=%d)"
        .. "\n  Y of buses, from their tracks: median %.3f oct, p90 %.3f (n=%d); of returns, from their sends (before their FX): median %.3f (n=%d)"
        .. "\n  no Y (\"?\"): %d track-sections of %d virtual instrument(s); tracks with files but no Y: %d"
        .. "\n  width: correlation off the truth, median %.3f, p90 %.3f (n=%d); before FX median %.3f (n=%d)"
        .. "\n  map: the window around the play position %.0f %% read on average while playing (%.0f windows a second, %.2f ms a cycle)\n  largest Y errors:\n%s"):format(
        median(ysrc), pct(ysrc, 0.9), pct(ysrc, 1.0), #ysrc, median(ey), #ey, median(eyf), #eyf, median(eyb), pct(eyb, 0.9), #eyb, median(eyr), #eyr, nq, nvst, nmiss,
        median(ec), pct(ec, 0.9), #ec, median(ecf), #ecf, ncover > 0 and 100 * cover / ncover or 0, ncover > 0 and wps / ncover or 0, ncover > 0 and ms / ncover or 0, table.concat(yworst, "\n"))
      table.sort(rows, function(a, b) return math.abs(a.dz) > math.abs(b.dz) end)
      local worst = {}
      for i = 1, math.min(5, #rows) do
        local r = rows[i]
        worst[#worst + 1] = ("    %s / %s: Z %.1f vs truth %.1f (%+.1f dB), X off %+.2f deg"):format(r.name, r.sec, r.z, r.truth, r.dz, r.dx)
      end
      local md = A.frames[#A.frames].md
      local ok = median(ex) <= 1.0 and (args.relative == "1" or median(ez) <= 1.5) and (#hz == 0 or (median(hx) <= 1.0 and median(hz) <= 1.5)) and ctx.y_ok
      return ok, ("%d frames; decay %.1f dB/s (vudecay %s); track-sections %d\n  own X: median %.2f deg, p90 %.2f, max %.2f (buses: median %.2f)\n  own Z: median %.2f dB, p90 %.2f, max %.2f (buses: median %.2f)\n  heard X: median %.2f deg, p90 %.2f, max %.2f (n=%d, of which %d under a bus with an image gap; without them median %.2f, max %.2f)\n  heard Z: median %.2f dB, p90 %.2f, max %.2f (n=%d)\n  largest own Z errors:\n%s"):format(
        #A.frames, md.decay, tostring(md.vudecay), #ez, median(ex), pct(ex, 0.9), pct(ex, 1.0), median(exb),
        median(ez), pct(ez, 0.9), pct(ez, 1.0), median(ezb), median(hx), pct(hx, 0.9), pct(hx, 1.0), #hx, hflag, median(hxu), pct(hxu, 1.0),
        median(hz), pct(hz, 0.9), pct(hz, 1.0), #hz, table.concat(worst, "\n")) .. ctx.ytext, 1.0
    end,
    function(tab, ctx)
      if ctx.reused then return nil, "no engine this time" end
      local f = EL.read("frame")
      EL.unregister(ctx.path)
      return f and f.state == "stopped", "engine stopped: " .. tostring(f and f.reason)
    end,
  },
}
