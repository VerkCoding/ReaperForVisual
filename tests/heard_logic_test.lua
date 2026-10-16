-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 5.3, method only: engine/rfv_heard.lua fed with the exact own powers of the rendered
-- stems (truth.json "own"), per section. Meters play no part, so this isolates the propagation.
--   Z against the share of the mix (truth.json "share", tools/truth_share.py);
--   X against the track rendered alone through its buses (truth.json "heard"), exact for pan
--   and linear FX such as a widener, which a scalar share cannot show.
-- nest must be exact apart from the widener's image, which is flagged; band shows what one gain
-- per section costs against a compressor that moves every 50 ms.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local HD = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_heard.lua")
local J = dofile(HERE .. ".." .. SEP .. "engine" .. SEP .. "rfv_json.lua")

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return J.decode(s)
end

local function stats(t)
  local s = {}
  for i, v in ipairs(t) do s[i] = math.abs(v) end
  table.sort(s)
  local function q(p) return s[math.max(1, math.min(#s, math.floor(#s * p + 0.5)))] or 0 end
  return ("median %.2f p90 %.2f max %.2f (n=%d)"):format(#s % 2 == 1 and s[(#s + 1) // 2] or ((s[#s // 2] or 0) + (s[#s // 2 + 1] or 0)) / 2, q(0.9), q(1), #s)
end

local function params(t, defmode, deflaw)
  local dp, law = t.dualpan or { -1, 1 }, t.panlaw or -1 -- the master's record has neither
  return { mode = (t.panmode == -1) and defmode or t.panmode, pan = t.pan, width = t.width or 1, dl = dp[1], dr = dp[2],
           law = (law == -1) and deflaw or law, vol = t.vol }
end

local function judge(name)
  local dir = L.env().truth .. SEP .. name
  local st, truth = read_json(dir .. SEP .. "structure.json"), read_json(dir .. SEP .. "truth.json")
  if not st or not truth then return nil, name .. ": no truth" end
  local n = #st.tracks
  local idx = {}
  for k, t in ipairs(st.tracks) do idx[t.guid] = k end
  local dry, way, bus = {}, {}, {}
  for k, t in ipairs(st.tracks) do
    dry[k] = (t.parent ~= J.null and t.parent) and idx[t.parent] or 0
    if t.folderdepth == 1 then bus[k] = { M = HD.matrix(params(t, 3, 1)), fx = t.fx > 0 } end
  end
  bus[0] = { M = HD.matrix(params(st.master, 3, 1) ), fx = false }
  local ex, ez, rows, fx_flagged = {}, {}, {}, {}
  local secs = { "all" }
  for _, r in ipairs(st.regions) do secs[#secs + 1] = r.name end
  for _, sec in ipairs(secs) do
    local own = {}
    for k, tt in ipairs(truth.tracks) do
      local o = tt.own[sec]
      if type(o) == "table" and o.level_db and o.level_db >= -70 then own[k] = { o.pl, o.pr } end
    end
    local heard, gain, image = HD.propagate(n, own, dry, way, bus)
    for k, tt in ipairs(truth.tracks) do
      local s = type(tt.share) == "table" and tt.share[sec]
      local a = type(tt.heard) == "table" and tt.heard[sec]
      if type(s) == "table" and heard[k] and s.level_db >= -70 then
        local h = heard[k]
        local dz = 10 * math.log(h[1] + h[2], 10) - s.level_db
        local dx = (HD.azimuth(h[1], h[2]) or 0) - ((type(a) == "table" and a.az_deg) or s.az_deg)
        local flagged = (image[dry[k]] or 0) > HD.IMAGE_DEG -- one section is long enough to count as lasting
        ez[#ez + 1] = dz
        if flagged then fx_flagged[#fx_flagged + 1] = ("%s/%s %+.1f deg"):format(st.tracks[k].name, sec, dx) else ex[#ex + 1] = dx end
        rows[#rows + 1] = { st.tracks[k].name .. (flagged and " (flagged: bus FX change the image)" or ""), sec, dx, dz }
      end
    end
  end
  table.sort(rows, function(a, b) return math.abs(a[4]) + math.abs(a[3]) / 10 > math.abs(b[4]) + math.abs(b[3]) / 10 end)
  local worst = {}
  for i = 1, math.min(4, #rows) do worst[#worst + 1] = ("    %s / %s: X %+.2f deg, Z %+.2f dB"):format(rows[i][1], rows[i][2], rows[i][3], rows[i][4]) end
  return ex, ez, ("%s: X %s deg (flagged apart: %s) | Z %s dB\n%s"):format(name, stats(ex),
    #fx_flagged > 0 and table.concat(fx_flagged, ", ") or "none", stats(ez), table.concat(worst, "\n"))
end

-- Who reaches the master under mute and solo (HD.audible), against what REAPER did in the step-5
-- review's probes (the muted master's meter decoded which tracks passed, 2026-10-12):
--   1 X top, 2 S (no master send, sends to 3), 3 B bus, 4 Y top, 5 R top with solo defeat,
--   6 F folder, 7 D child with solo defeat, 8 C child, 9 C2 child (probe 8's sibling).
local function audibility()
  local dry = { 0, 3, 0, 0, 0, 0, 6, 6, 6 }
  local via = { "folder", "send", "folder", "folder", "folder", "folder", "folder", "folder", "folder" }
  local defeat = { false, false, false, false, true, false, true, false, false }
  local names = { "X", "S", "B", "Y", "R", "F", "D", "C", "C2" }
  local cases = {
    -- name, solo {track = mode}, muted {tracks}, tracks that must be heard (all others silenced)
    { "nothing soloed", {}, {}, "X S B Y R F D C C2" },
    { "S solo (not in place): stops at its send", { [2] = 1 }, {}, "R D F" },
    { "S solo in place", { [2] = 2 }, {}, "S B R D F" },
    { "B solo: what feeds it passes", { [3] = 1 }, {}, "S B R D F" },
    { "B solo in place", { [3] = 2 }, {}, "S B R D F" },
    { "Y solo", { [4] = 1 }, {}, "Y R D F" },
    { "C solo in place: its folder carries it, its sibling is cut", { [8] = 2 }, {}, "C F R D" },
    { "C solo (not in place): the folder still carries it", { [8] = 1 }, {}, "C F R D" },
    { "F solo: its children pass", { [6] = 2 }, {}, "F D C C2 R" },
    { "F muted: its children are silenced", {}, { [6] = true }, "X S B Y R" },
    { "C muted", {}, { [8] = true }, "X S B Y R F D C2" },
    { "B muted: S behind it too", {}, { [3] = true }, "X Y R F D C C2" },
  }
  local out, ok = {}, true
  for _, c in ipairs(cases) do
    local solo, muted, hop = {}, {}, {}
    for k = 1, #dry do solo[k] = c[2][k] or 0; muted[k] = c[3][k] or false end
    local A = HD.audible(#dry, dry, via, solo, defeat, muted, hop)
    local heard = {}
    for k = 1, #dry do if not A.silenced[k] then heard[#heard + 1] = names[k] end end
    local want = {}
    for w in c[4]:gmatch("%S+") do want[w] = true end
    local good = true
    for k = 1, #dry do if (want[names[k]] or false) == A.silenced[k] then good = false end end
    if not good then ok = false end
    out[#out + 1] = ("  %-58s heard %-20s %s"):format(c[1], table.concat(heard, " "), good and "ok" or ("<-- want " .. c[4]))
  end
  return ok, out
end

-- The FX gain with a side send, a bus that falls silent, and a send taken before the fader.
local function gains()
  local I = { 1, 0, 0, 1 }
  local out, ok = {}, true
  -- bus 2 (FX, gain 2 in fact) holds track 1 (power 1+1) and gets a side send from track 3
  -- (power 2+2, send at 0.5 = 0.25 in power): it measures (2 + 1) x 2 = 6
  local own = { { 1, 1 }, { 3, 3 }, { 2, 2 } }
  local dry = { 2, 0, 0 }
  local bus = { [2] = { M = I, fx = true }, [0] = { M = I, fx = false } }
  local sides = { { src = 3, dst = 2, M = { 0.5, 0, 0, 0.5 }, pre = false, pass = true } }
  local h, g = HD.propagate(3, own, dry, {}, bus, { sides = sides })
  local good = math.abs(g[2] - 2) < 1e-9 and math.abs(h[1][1] - 2) < 1e-9
  out[#out + 1] = ("  side send counted: bus gain %.3f (2), track heard %.3f (2) %s"):format(g[2], h[1][1], good and "ok" or "<--")
  ok = ok and good
  local h2, g2 = HD.propagate(3, own, dry, {}, bus) -- the old way, for the record
  out[#out + 1] = ("    without it the gain was %.3f and the track %.1f dB too loud"):format(g2[2], 10 * math.log(h2[1][1] / 2, 10))
  -- the same bus silent while its input plays: gain 0
  local own3 = { { 1, 1 }, nil, nil }
  local h3, g3 = HD.propagate(3, own3, dry, {}, bus)
  good = g3[2] == 0 and h3[1][1] == 0
  out[#out + 1] = ("  bus with FX silent while its input plays: gain %s, heard power %s %s"):format(g3[2], h3[1][1], good and "ok" or "<--")
  ok = ok and good
  -- a track at fader 0.5 sent before its fader to a plain bus: heard at its pre-fader level
  local M = HD.matrix({ mode = 3, pan = 0, width = 1, dl = 0, dr = 0, law = 1, vol = 0.5 })
  local tl, tr = HD.untap(M, 0.25, 0.25)
  local h4 = HD.propagate(2, { { 0.25, 0.25 }, nil }, { 2, 0 }, { I }, { [2] = { M = I, fx = false }, [0] = { M = I, fx = false } },
    { tap = { { tl, tr } }, outm = { 3 } })
  good = math.abs(h4[1][1] - 1) < 1e-9
  out[#out + 1] = ("  pre-fader send: heard power %.3f (1, the fader undone) %s"):format(h4[1][1], good and "ok" or "<--")
  return ok and good, out
end

return {
  name = "heard-logic",
  steps = { function()
    local out = {}
    local ok = true
    local ok_a, lines_a = audibility()
    out[#out + 1] = "mute and solo, against REAPER's behaviour:"
    for _, l in ipairs(lines_a) do out[#out + 1] = l end
    local ok_g, lines_g = gains()
    out[#out + 1] = "FX gain and pre-fader sends:"
    for _, l in ipairs(lines_g) do out[#out + 1] = l end
    ok = ok_a and ok_g
    for _, name in ipairs({ "nest", "band" }) do
      local ex, ez, line = judge(name)
      if not ex then return false, ez end
      out[#out + 1] = line
      if name == "nest" then -- exact; the widener's image is flagged, not judged
        for i = 1, #ez do if math.abs(ez[i]) > 0.05 then ok = false end end
        for i = 1, #ex do if math.abs(ex[i]) > 0.05 then ok = false end end
      end
    end
    return ok, table.concat(out, "\n")
  end },
}
