-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- X and Z from REAPER's track meters (roadmap step 5). Pure Lua: the engine feeds it the two
-- values of Track_GetPeakInfo every tick; tools/meter_reference.py is the same pipeline in
-- Python, and the two are compared on the same readings by tests/meter_logic_test.lua.
--
-- What the meter is (measured on REAPER 7.82, 2026-10-11): it refreshes about every 46.7 ms; at
-- each refresh it shows the peak since the last one, or, if that is lower, its previous value
-- fallen by one fixed step (1.4 dB with vudecay = 30 dB/s). The engine reads it every ~31 ms,
-- so it sees most refreshes once and some twice.
--
--   1. A reading equal to the previous one is the same refresh, unless it has stood for longer
--      than REPEAT_GAP (more than one refresh, less than two reads): then the peak repeated,
--      and it counts with the previous reading's status (a steady tone stays exact; a decaying
--      tail whose refresh came late stays on the line).
--   2. The meter shows max(peak, decay line), and the line falls about one step per refresh
--      (REAPER's refresh wobbles between ~46 and ~47 ms, so a step is 1.38 to 1.41 dB, and a
--      stall puts several steps into one reading). So, per channel, a reading that fell by at
--      least STEP_MIN of a step is on the line: the true peak was at most that, and CENS x the
--      reading is used. A smaller fall, or a rise, is the exact peak of that refresh. A reading
--      under FLOOR (-100 dBFS) is silence.
--   3. A refresh that saw no audio: REAPER renders audio in bursts, so a steady tone's meter
--      now and then dips one step and comes straight back. A reading on the line between two
--      exact ones, with the next one back up, is such a refresh and is dropped once the next
--      reading shows it (without this a steady sine read 1.5 dB low).
--   4. X over the last X_WIN s: tangent law (speakers at +-30 deg) on the summed squares.
--   5. Z over the last Z_WIN s: 10 log10(mean S) - (CREST_A + CREST_B * 10 log10(max S / mean S)),
--      S = L^2 + R^2: the level the peaks overstate by the signal's crest factor. No exact
--      reading in the window means silence: no X, no Z.
--
-- The step is measured live: the commonest fall between two readings, over all tracks
-- (a decaying meter falls by exactly one step per refresh; music falls by anything). REAPER
-- 7.82 with vudecay 30: 1.4148 dB, down to -155 dB. Older falls count half every OBS_HALF
-- falls, so a changed setting is followed. The decay rate is the median of the last RUNS whole
-- decays' rates (dB over seconds), taken while playing only: when stopped, a meter left without
-- audio (the device closed while REAPER is in the background) can drop at once, and those drops
-- once pulled the reported refresh from 47 to 42 ms. The refresh is the step over that rate.
--
-- Revised after the step-5 review (2026-10-12): REAPER's meter is raised at once by the audio
-- thread and lowered one step at its UI meter ticks (inside one blocking script call it rose on
-- noise and never fell on a decaying tone); the ticks come from REAPER's meter update setting
-- (vuupdfreq 30 Hz = 33.3 ms, which Windows' 15.6 ms timer turns into 46.9 ms here). The crest
-- coefficients depend on the step and the refresh (other settings, emulated): MT.crest.

local MT = {}

MT.CENS = 0.4                      -- a reading on the decay line: the peak taken as this x it
MT.X_WIN, MT.Z_WIN = 0.5, 2.0      -- seconds (the owner's choice, 2026-10-11)
MT.CREST_A, MT.CREST_B = 4.480, 0.467  -- fitted on REAPER's own readings of the band fixture
                                       -- (tests/meter_record_test.lua, tools/meter_reference.py --live-reads)
MT.STEP_MIN = 0.95                 -- a fall of at least this many steps is the decay line
MT.REPEAT_GAP = 0.055              -- s: a reading standing this long is a repeated peak
MT.FLOOR = 1e-5                    -- -100 dBFS: below is silence
MT.CAP = 96                        -- readings kept per track (2 s is ~43 refreshes)
MT.OBS_HALF = 400                  -- falls between two halvings of the step histogram
MT.RUNS = 32                       -- decay runs kept for the rate

local log10, sqrt, atan, floor, abs = math.log10 or function(x) return math.log(x, 10) end, math.sqrt, math.atan, math.floor, math.abs
local T30 = math.tan(math.rad(30))
local function db(x) return 20 * log10(x) end

-- The decay, shared by all tracks of a tab. fallback_step: dB per refresh until measured.
function MT.new_decay(fallback_step, fallback_refresh)
  return { hist = {}, sums = {}, n = 0, best = 0, since = 0, step = fallback_step or 1.4148, refresh = fallback_refresh or 0.04716,
           measured = false, rates = {}, rate_i = 0, rate = nil, playing = true }
end

local function observe_drop(d, drop)
  if drop < 0.3 or drop > 6 then return end
  local bin = floor(drop * 100 + 0.5)
  local h = (d.hist[bin] or 0) + 1
  d.hist[bin] = h
  d.sums[bin] = (d.sums[bin] or 0) + drop
  d.n, d.since = d.n + 1, d.since + 1
  if h > d.best then d.best, d.mode_bin = h, bin end
  if d.since >= MT.OBS_HALF then -- older falls count half: the mode stays where it was unless the falls moved
    for b, c in pairs(d.hist) do d.hist[b], d.sums[b] = c / 2, d.sums[b] / 2 end
    d.best, d.since = d.best / 2, 0
  end
  if d.n >= 40 and d.best >= 10 then
    d.step = d.sums[d.mode_bin] / d.hist[d.mode_bin] -- the mean of the falls in the commonest 0.01 dB bin
    d.measured = true
  end
end

function MT.decay_db_per_s(d) return d.rate or d.step / d.refresh end

-- Crest coefficients for a meter of this step (dB per refresh, as measured) and refresh (s):
-- offsets from the measured setting (47.16 ms, 1.4148 dB) fitted on the emulation of other
-- settings (tools/meter_reference.py), interpolated in log step along each refresh row, then
-- linearly between rows; outside the grid, its edge. Engine reads come every ~31 ms, and a meter
-- that refreshes faster is seen as refreshing at the read rate with a bigger step, so the grid
-- starts at 31.25 ms.
-- { refresh s, { { step dB, offset to CREST_A, offset to CREST_B }, ... } } (decay 10, 20, 30, 45,
-- 60 and 120 dB/s on each row; band fixture, held emulation, 2026-10-12)
MT.CREST_GRID = {
  { 0.03125, { { 0.3125, -1.950, 0.186 }, { 0.6250, -0.923, 0.006 }, { 0.9375, -0.212, -0.100 }, { 1.4062, 0.397, -0.179 }, { 1.8750, 0.704, -0.211 }, { 3.7500, 0.965, -0.209 } } },
  { 0.04716, { { 0.4716, -1.657, 0.269 }, { 0.9432, -0.575, 0.089 }, { 1.4148, 0.000, 0.000 }, { 2.1222, 0.472, -0.062 }, { 2.8296, 0.669, -0.081 }, { 5.6592, 0.803, -0.072 } } },
  { 0.06250, { { 0.6250, -1.308, 0.333 }, { 1.2500, -0.309, 0.167 }, { 1.8750, 0.221, 0.084 }, { 2.8125, 0.601, 0.033 }, { 3.7500, 0.785, 0.017 }, { 7.5000, 0.865, 0.026 } } },
  { 0.09375, { { 0.9375, -0.937, 0.454 }, { 1.8750, -0.097, 0.305 }, { 2.8125, 0.285, 0.235 }, { 4.2188, 0.593, 0.187 }, { 5.6250, 0.726, 0.171 }, { 11.2500, 0.799, 0.179 } } },
}
local memo = {} -- the last step and refresh asked and their answer: every track asks the same each frame
function MT.crest(step, refresh)
  local G = MT.CREST_GRID
  if not G or not step or not refresh then return MT.CREST_A, MT.CREST_B end
  if memo.step == step and memo.refresh == refresh and memo.G == G then return memo.a, memo.b end
  local a, b = MT.crest_grid(G, step, refresh)
  memo.step, memo.refresh, memo.G, memo.a, memo.b = step, refresh, G, a, b
  return a, b
end
function MT.crest_grid(G, step, refresh)
  local function row(r)
    local pts = r[2]
    local x = math.log(step)
    if x <= math.log(pts[1][1]) then return pts[1][2], pts[1][3] end
    for i = 1, #pts - 1 do
      local x1, x2 = math.log(pts[i][1]), math.log(pts[i + 1][1])
      if x <= x2 then
        local f = (x - x1) / (x2 - x1)
        return pts[i][2] + f * (pts[i + 1][2] - pts[i][2]), pts[i][3] + f * (pts[i + 1][3] - pts[i][3])
      end
    end
    return pts[#pts][2], pts[#pts][3]
  end
  local da, dbb
  if refresh <= G[1][1] then da, dbb = row(G[1])
  elseif refresh >= G[#G][1] then da, dbb = row(G[#G])
  else
    for i = 1, #G - 1 do
      if refresh <= G[i + 1][1] then
        local f = (refresh - G[i][1]) / (G[i + 1][1] - G[i][1])
        local a1, b1 = row(G[i])
        local a2, b2 = row(G[i + 1])
        da, dbb = a1 + f * (a2 - a1), b1 + f * (b2 - b1)
        break
      end
    end
  end
  return MT.CREST_A + da, MT.CREST_B + dbb
end

-- One track's readings. Running sums over the two windows and a deque for the largest reading,
-- so an estimate costs the same however many readings the windows hold (it was 0.62 ms per frame
-- for 84 sounding tracks when the windows were summed afresh each time).
function MT.new_track()
  return { l = 0, r = 0, t = -1, cl = false, cr = false,
           pl = {}, pr = {}, ss = {}, tt = {}, ex = {}, miss = {}, seq = 0,
           zt = 1, xt = 1, zsum = 0, zn = 0, zex = 0, xl = 0, xr = 0, dq = {}, dqh = 1, dqt = 0,
           last_ex = false, last_c = false, last_ds = 0, before_ex = false }
end

local CAP = MT.CAP
local function pos(q) return (q - 1) % CAP + 1 end

-- Take readings that have left the windows out of the sums.
local function evict(s, t)
  while s.zt <= s.seq and t - s.tt[pos(s.zt)] >= MT.Z_WIN do
    local p = pos(s.zt)
    if not s.miss[p] then
      s.zsum, s.zn = s.zsum - s.ss[p], s.zn - 1
      if s.ex[p] then s.zex = s.zex - 1 end
    end
    s.zt = s.zt + 1
  end
  while s.xt <= s.seq and t - s.tt[pos(s.xt)] >= MT.X_WIN do
    local p = pos(s.xt)
    if not s.miss[p] then s.xl, s.xr = s.xl - s.pl[p], s.xr - s.pr[p] end
    s.xt = s.xt + 1
  end
  if s.zn <= 0 then s.zsum, s.zn, s.zex = 0, 0, 0 end -- no rounding left over once empty
  if s.xt > s.seq then s.xl, s.xr = 0, 0 end
  local dq = s.dq
  while s.dqh <= s.dqt do
    local q = dq[(s.dqh - 1) % CAP + 1]
    if q >= s.zt and not s.miss[pos(q)] then break end
    s.dqh = s.dqh + 1
  end
end

-- Is a fall from p to v the decay line? Returns that, and the fall in dB.
local function on_line(p, v, step)
  if v <= 0 or p <= 0 or v >= p then return nil end
  local drop = db(p / v)
  return drop >= MT.STEP_MIN * step or nil, drop
end

-- A decay run on the left channel, for the decay rate: from the reading before its first step
-- to its last step, while playing. Closed when the run ends; only runs of 8 steps or more count.
local function run_close(s, d)
  if s.run_t and s.run_lt and s.run_lv > 0 and s.run_play and d.playing then
    local fall, dt = db(s.run_v / s.run_lv), s.run_lt - s.run_t
    if fall >= 8 * d.step and dt > 0 then
      d.rate_i = d.rate_i % MT.RUNS + 1
      d.rates[d.rate_i] = fall / dt
      if #d.rates >= 5 then
        local r = {}
        for i, v in ipairs(d.rates) do r[i] = v end
        table.sort(r)
        d.rate = #r % 2 == 1 and r[(#r + 1) // 2] or (r[#r // 2] + r[#r // 2 + 1]) / 2
        d.refresh = d.step / d.rate
      end
    end
  end
  s.run_t, s.run_lt = nil, nil
end

-- Feed one reading. Returns true when it was a new refresh.
function MT.feed(s, d, t, l, r)
  local kl, kr
  if l == s.l and r == s.r then
    if (l == 0 and r == 0) or t - s.t < MT.REPEAT_GAP then return false end
    kl, kr = s.cl or nil, s.cr or nil -- a repeated peak: as the reading it repeats
  else
    local dl, dr
    kl, dl = on_line(s.l, l, d.step)
    kr, dr = on_line(s.r, r, d.step)
    if dl then observe_drop(d, dl) end
    if dr then observe_drop(d, dr) end
    if kl then
      if not s.run_t then s.run_t, s.run_v, s.run_play = s.t, s.l, d.playing end
      s.run_lt, s.run_lv = t, l
    elseif s.run_t then
      run_close(s, d)
    end
  end
  evict(s, t)
  s.cl, s.cr = kl and true or false, kr and true or false
  local rl = (l < MT.FLOOR and 0) or (kl and MT.CENS * l) or l
  local rr = (r < MT.FLOOR and 0) or (kr and MT.CENS * r) or r
  local ex = (not kl and l >= MT.FLOOR) or (not kr and r >= MT.FLOOR)
  local ds = l * l + r * r
  if ex and s.last_c and s.before_ex and ds >= s.last_ds and s.seq > 0 then
    -- the last reading was a refresh without audio: out of the sums
    local p = pos(s.seq)
    if not s.miss[p] then
      s.miss[p] = true
      if s.seq >= s.zt then s.zsum, s.zn = s.zsum - s.ss[p], s.zn - 1; if s.ex[p] then s.zex = s.zex - 1 end end
      if s.seq >= s.xt then s.xl, s.xr = s.xl - s.pl[p], s.xr - s.pr[p] end
    end
  end
  s.seq = s.seq + 1
  local q = s.seq
  local p = pos(q)
  local pl, pr = rl * rl, rr * rr
  local v = pl + pr
  s.pl[p], s.pr[p], s.ss[p], s.tt[p], s.ex[p], s.miss[p] = pl, pr, v, t, ex, false
  s.zsum, s.zn = s.zsum + v, s.zn + 1
  if ex then s.zex = s.zex + 1 end
  s.xl, s.xr = s.xl + pl, s.xr + pr
  local dq = s.dq
  while s.dqt >= s.dqh and s.ss[pos(dq[(s.dqt - 1) % CAP + 1])] <= v do s.dqt = s.dqt - 1 end
  s.dqt = s.dqt + 1
  dq[(s.dqt - 1) % CAP + 1] = q
  s.before_ex, s.last_ex, s.last_c, s.last_ds = s.last_ex, ex, (not ex) and (kl or kr) and true or false, ds
  s.l, s.r, s.t = l, r, t
  return true
end

-- X (degrees) and Z (dB) at time t, or nil, nil while silent. With d (the tab's decay), the
-- crest coefficients follow its measured step and refresh (MT.crest); without, the ones fitted
-- at the measured setting.
function MT.estimate(s, t, d)
  evict(s, t)
  if s.zex <= 0 or s.zsum <= 0 or s.zn <= 0 or s.dqh > s.dqt then return nil, nil end
  local mean = s.zsum / s.zn
  local max = s.ss[pos(s.dq[(s.dqh - 1) % CAP + 1])]
  local A, B = MT.CREST_A, MT.CREST_B
  if d and d.measured then A, B = MT.crest(d.step, d.refresh) end
  local z = 10 * log10(mean) - (A + B * 10 * log10(max / mean))
  local x
  local xl, xr = s.xl, s.xr
  if xl < 0 then xl = 0 end
  if xr < 0 then xr = 0 end
  if xl + xr > 0 then
    local a, b = sqrt(xl), sqrt(xr)
    x = math.deg(atan((b - a) / (a + b) * T30))
  end
  return x, z
end

return MT
