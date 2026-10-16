-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Where a track is HEARD: its own output carried up its main path, bus by bus (roadmap step 5,
-- revised after its review). Pure Lua; the engine supplies the numbers. At each bus:
--   1. the way in: a folder link as it is, a send by its volume, pan and mono switch (a send
--      taken before the fader starts from the track's output with its fader and pan undone);
--   2. the bus's FX gain, when its FX chain holds active FX: what its meter measures over what
--      its inputs predict (measured powers, so a compressor's work on the whole group is shared
--      out in proportion: "its share of the mix", see tools/truth_share.py). Every audio send
--      into the bus counts in the prediction, not only the main paths; a bus that sounds nothing
--      while its inputs play has gain 0 (a gate, or FX that silence it);
--   3. the bus's fader and pan, as REAPER's pan matrix (measured in step 2, DESIGN.md), after
--      its pre-FX pan when it has one.
-- Then the master's fader and pan (and its FX gain, if it has FX). The left/right correlation of
-- a track is not known before step 7, so crossfeed (stereo pan mode, width) assumes none.
--
-- What is silenced on the way (HD.audible), as measured on REAPER 7.82 (DESIGN.md):
--   * a muted track, or a muted bus anywhere above it. A muted track's meter falls silent; a
--     child's meter still shows its signal when its folder is muted;
--   * under solo, every track whose signal does not reach the master. A soloed track passes, and
--     so does everything feeding a soloed bus (folder children and sends alike); folder parents
--     pass a soloed child; "solo in place" also passes the sends on its way, plain solo stops at
--     a send to a bus that is not soloed; solo defeat always passes. The meters of tracks muted
--     by solo still show their signal, except a sibling of a soloed child, which is cut on its
--     way into the folder (so the folder's meter shows only what passes).
--
-- Pan parameters p = { mode, pan, width, dl, dr, law, vol, prepan }: mode as I_PANMODE (-1
-- resolved to the project default by the caller), law as D_PANLAW in linear gain at the centre
-- (1 = 0 dB, 0.708 = -3 dB sine/cosine, 0.501 = -6 dB linear; other laws are approximated by the
-- sine/cosine curve scaled to their centre), vol the linear gain of every volume stage together,
-- prepan the pre-FX pan (a balance before the FX, measured: pre-FX right 0.3 and pan right 0.5
-- left the left channel at 0.7 x 0.5).

local HD = {}
HD.IMAGE_DEG = 4.0  -- a lasting gap this large flags a bus (the band fixture's room mics: 15% of
                    -- frames above it, never for long; a widener: 9.3 deg throughout)
local sqrt, cos, sin, rad, abs = math.sqrt, math.cos, math.sin, math.rad, math.abs

local function law_gains(p, law)
  if abs(law - 1) < 0.01 then
    return (p <= 0 and 1 or 1 - p), (p >= 0 and 1 or 1 + p)
  elseif abs(law - 0.5012) < 0.01 then
    return (1 - p) / 2, (1 + p) / 2
  end
  local th = rad((p + 1) * 45)
  local k = law / 0.7071 -- the sine/cosine curve has its centre at -3 dB; scale it to this law
  return cos(th) * k, sin(th) * k
end

-- Amplitude matrix {ll, rl, lr, rr}: out L = ll*in L + rl*in R, out R = lr*in L + rr*in R.
function HD.matrix(p)
  local ll, rl, lr, rr
  if p.mode == 6 then -- dual pan: each channel by the 0 dB law on its own pan
    local a, b = law_gains(p.dl, 1)
    local c, d = law_gains(p.dr, 1)
    ll, lr, rl, rr = a, b, c, d
  elseif p.mode == 5 then -- width first, then a stereo pan
    local w, q = p.width, p.pan
    local w1, w2 = (1 + w) / 2, (1 - w) / 2
    local P11, P12, P21, P22
    if q >= 0 then P11, P12, P21, P22 = 1 - q, 0, q / 2, 1 - q / 2
    else P11, P12, P21, P22 = 1 - abs(q) / 2, abs(q) / 2, 0, 1 - abs(q) end
    ll, rl = P11 * w1 + P12 * w2, P11 * w2 + P12 * w1
    lr, rr = P21 * w1 + P22 * w2, P21 * w2 + P22 * w1
  else -- balance (3), and classic (0) treated alike
    local gl, gr = law_gains(p.pan, p.law)
    ll, rl, lr, rr = gl, 0, 0, gr
  end
  if p.prepan and p.prepan ~= 0 then -- the pre-FX pan scales each input channel first
    local gl, gr = law_gains(p.prepan, p.law)
    ll, lr, rl, rr = ll * gl, lr * gl, rl * gr, rr * gr
  end
  local v = p.vol
  return { ll * v, rl * v, lr * v, rr * v }
end

-- A send's way in: volume, its pan (balance, 0 dB law) and the mono switch.
function HD.send_matrix(vol, pan, mono)
  local gl, gr = law_gains(pan, 1)
  if mono then return { 0.5 * gl * vol, 0.5 * gl * vol, 0.5 * gr * vol, 0.5 * gr * vol } end
  return { gl * vol, 0, 0, gr * vol }
end

-- Powers through a matrix, with left/right correlation rho (0 when unknown).
function HD.through(M, pl, pr, rho)
  local x = (rho or 0) * sqrt(pl * pr)
  return M[1] * M[1] * pl + M[2] * M[2] * pr + 2 * M[1] * M[2] * x,
         M[3] * M[3] * pl + M[4] * M[4] * pr + 2 * M[3] * M[4] * x
end

-- Left, right and cross powers through a matrix (the cross power a matrix makes, a mono send or
-- a width setting, is kept for the next one).
function HD.cov(M, l, r, c)
  local a, b, d, e = M[1], M[2], M[3], M[4]
  return a * a * l + b * b * r + 2 * a * b * c,
         d * d * l + e * e * r + 2 * d * e * c,
         a * d * l + b * e * r + (a * e + b * d) * c
end

-- The powers before a matrix, from the powers after it (uncorrelated channels: solve the 2 x 2
-- system of squared gains). For a send taken before the fader: the track's own meter is after
-- its fader and pan. A channel the matrix silences cannot be recovered; it is taken as the
-- other one (a hard pan of a mono source).
function HD.untap(M, ol, orr)
  local a, b, c, d = M[1] * M[1], M[2] * M[2], M[3] * M[3], M[4] * M[4]
  local det = a * d - b * c
  if abs(det) > 1e-9 * math.max(1, (a + b) * (c + d)) then
    local pl, pr = (d * ol - b * orr) / det, (a * orr - c * ol) / det
    if pl >= 0 and pr >= 0 then return pl, pr end
  end
  local s = a + b + c + d
  if s <= 0 then return 0, 0 end
  local p = (ol + orr) / s -- both channels alike
  return p, p
end

local T30 = math.tan(math.rad(30))
function HD.azimuth(pl, pr)
  local l, r = sqrt(pl), sqrt(pr)
  if l + r <= 0 then return nil end
  return math.deg(math.atan((r - l) / (l + r) * T30))
end

-- Powers from an azimuth (deg) and a level (dB): the inverse of the tangent law.
function HD.powers(x, z)
  local p = 10 ^ (z / 10)
  if not x then return p / 2, p / 2 end
  local q = math.tan(math.rad(x)) / T30
  local l, r = (1 - q) / 2, (1 + q) / 2
  local s = l * l + r * r
  return p * l * l / s, p * r * r / s
end

-- Who reaches the master now, from the state of every track:
--   n, dry, via   main path (dry[k]: destination index, 0 = master, nil = nowhere) and how
--                 ("folder" or "send")
--   solo[k]       0, 1 (solo) or 2 (solo in place); defeat[k] solo defeat; muted[k] mute
--                 button or Mute envelope; hopmute[k] its main-path send muted by an envelope
-- Returns a = { silenced[k] (its own signal cannot reach the master), pass[k] (its output enters
-- its main-path destination: what that bus's meter holds), any (a track is soloed), live[k] (its
-- signal reaches the master under the solo), under(k) (k or a bus above it is soloed) }.
function HD.audible(n, dry, via, solo, defeat, muted, hopmute)
  local any = false
  for k = 1, n do if (solo[k] or 0) > 0 then any = true; break end end
  local whole = {}
  local function under_solo(k) -- k, or a bus on its main path, is soloed
    local v = whole[k]
    if v ~= nil then return v end
    whole[k] = false -- a loop in the routing ends here
    local d = dry[k]
    v = (solo[k] or 0) > 0 or (d ~= nil and d > 0 and under_solo(d)) or false
    whole[k] = v
    return v
  end
  local function reaches(k) -- under solo: does k's own signal reach the master?
    if defeat[k] then return true end
    local m = solo[k] or 0
    if m == 0 and not under_solo(k) then return false end
    local x, guard = k, 0
    while dry[x] and dry[x] > 0 and guard < 64 do
      local d = dry[x]
      if (solo[d] or 0) > 0 then m = solo[d]
      elseif m == 1 and via[x] == "send" and not under_solo(d) then return false end
      x, guard = d, guard + 1
    end
    return true
  end
  local silenced, pass, live, anc, cut = {}, {}, {}, {}, {}
  for k = 1, n do
    local s = muted[k] or hopmute[k] or false
    local x, guard = k, 0
    while not s and dry[x] and dry[x] > 0 and guard < 64 do
      x, guard = dry[x], guard + 1
      s = muted[x] or hopmute[x] or false
    end
    cut[k] = s
    live[k] = not any or reaches(k)
  end
  if any then -- a folder or bus that carries a track that reaches the master passes that part
    for k = 1, n do
      if live[k] and not cut[k] then
        local x, guard = k, 0
        while dry[x] and dry[x] > 0 and guard < 64 do x, guard = dry[x], guard + 1; anc[x] = true end
      end
    end
  end
  -- silenced: muted on the way, or under solo neither reaching the master nor carrying a track
  -- that does (its meter then holds only that track: a soloed child's folder, measured)
  for k = 1, n do silenced[k] = cut[k] or (any and not live[k] and not anc[k]) or false end
  for k = 1, n do pass[k] = not muted[k] and not hopmute[k] and (not any or live[k] or anc[k] or false) end
  return { silenced = silenced, pass = pass, any = any, live = live, under = under_solo }
end

-- Carry every track up its main path.
--   n       track count
--   own     own[k] = { pl, pr } or nil (silent)
--   dry     dry[k] = index of its main-path destination (0 = master, nil = nowhere)
--   way     way[k] = matrix of its way in (nil for a folder link)
--   bus     bus[b] = { M = pan matrix incl. every volume stage, fx = true when its FX gain applies,
--           out = measured powers (the master only; other buses use own[b]) }; bus[0] the master
--   o       optional:
--     silenced[k]  heard nowhere (HD.audible)
--     pass[k]      its output enters its destination (HD.audible); counts in the prediction
--     tap[k]       its powers before its fader and pan, for sends taken there
--     outm[k]      how its main path leaves it: 0 after the fader (folder or post-fader send),
--                  3 after the FX before the fader, 1 before the FX
--     sides        other audio sends into buses: { src, dst, M, pre (taken before the fader),
--                  pass (reaches its bus under solo) }
--     rho[k]       the left/right correlation of k's output (step 7, from its files); with it
--                  the cross power is carried through every matrix on the way (0 when unknown)
--     gain[b]      fixed FX gains (step 9a, stopped: learned while playing; 1 where absent)
--                  instead of gains measured from the buses' meters
-- Returns heard[k] = { pl, pr }, gain[b] (FX gain per bus, 1 where none applies) and image[b]:
-- for a bus with FX, how far (degrees) its measured output sits from where its inputs put it,
-- the "image gap". FX that move or widen the image open a lasting gap, and then the heard X of
-- its inputs is off (a widener: 9.3 deg); correlated inputs panned apart (room mics) open one
-- too while each input's heard X stays right, and the two cannot be told apart from meters.
-- The engine flags a bus whose gap, smoothed over about a second, stays above IMAGE_DEG.
function HD.propagate(n, own, dry, way, bus, o)
  o = o or {}
  local silenced, pass, tap, outm, sides = o.silenced or {}, o.pass, o.tap or {}, o.outm or {}, o.sides or {}
  local rho = o.rho or {}
  local function source(k, pre)
    local p = pre and tap[k] or own[k]
    if p then
      local r = not pre and rho[k] or 0 -- the correlation is known after the fader (its output)
      return p[1], p[2], r * sqrt(p[1] * p[2])
    end
  end
  -- the FX gain of each bus: measured output over the output its inputs predict
  local pred_l, pred_r = {}, {}
  local function add(d, pl, pr, pc)
    local ql, qr = HD.cov(bus[d].M, pl, pr, pc)
    pred_l[d], pred_r[d] = (pred_l[d] or 0) + ql, (pred_r[d] or 0) + qr
  end
  for k = 1, n do
    local d = dry[k]
    if d and bus[d] and (not pass or pass[k]) then
      local pl, pr, pc = source(k, (outm[k] or 0) ~= 0)
      if pl then
        if way[k] then pl, pr, pc = HD.cov(way[k], pl, pr, pc) end
        add(d, pl, pr, pc)
      end
    end
  end
  for _, s in ipairs(sides) do
    if bus[s.dst] and s.pass ~= false then
      local pl, pr, pc = source(s.src, s.pre)
      if pl then add(s.dst, HD.cov(s.M, pl, pr, pc)) end
    end
  end
  local gain, image = {}, {}
  for b, info in pairs(bus) do
    gain[b] = 1
    local pred = (pred_l[b] or 0) + (pred_r[b] or 0)
    if o.gain then
      gain[b] = o.gain[b] or 1
    elseif info.fx and pred > 0 then
      local m = b > 0 and own[b] or info.out
      if m then
        gain[b] = (m[1] + m[2]) / pred
        local xm, xp = HD.azimuth(m[1], m[2]), HD.azimuth(pred_l[b], pred_r[b])
        if xm and xp then image[b] = abs(xm - xp) end
      else
        gain[b] = 0 -- its inputs play and it sounds nothing: its FX silence them
      end
    end
  end
  local heard = {}
  for k = 1, n do
    if own[k] and not silenced[k] then
      local pl, pr, pc = source(k, (outm[k] or 0) ~= 0)
      local x, guard = k, 0
      while pl and dry[x] and bus[dry[x]] and guard < 64 do
        local d = dry[x]
        if way[x] then pl, pr, pc = HD.cov(way[x], pl, pr, pc) end
        local m = d > 0 and (outm[d] or 0) or 0 -- where d's own way out leaves it
        if m ~= 1 then pl, pr, pc = pl * gain[d], pr * gain[d], pc * gain[d] end
        if m == 0 then pl, pr, pc = HD.cov(bus[d].M, pl, pr, pc) end
        if d == 0 then break end
        x, guard = d, guard + 1
      end
      if pl and dry[x] ~= nil then heard[k] = { pl, pr } end
    end
  end
  return heard, gain, image
end

-- Where a level comes from, as shares { here, elsewhere, none } of a part's power (step 9a):
-- its FX gain learned at this place of the song, learned elsewhere in it, or never learned. A
-- part is known here only where both what it carries and the gain on its way are. Every gain is
-- learned in the same passes of the song, so the stages are known at the same places: their
-- shares combine as the worse of the two at each place (step 9a review: multiplied as if
-- independent, four bus stages each 75 % known here gave 32 % on the owner's mix).
function HD.degrade(v, g)
  if not g then return v end
  local here, never = math.min(v[1], g[1]), math.max(v[3], g[3])
  return { here, math.max(0, 1 - here - never), never }
end

-- Stopped (step 9a), no meter measures a bus: its output is what its inputs bring, through its
-- pan matrix and every volume stage, times its FX gain as learned while playing. Inputs as
-- HD.propagate counts them (main paths that pass, other audio sends into it). Fills own[b] for
-- every bus with inputs (0: the master), inner buses first, in place:
--   own[b] = its own files' part as given (a bus with items, rare) + inputs x o.gain[b] (1 where
--            absent);
--   o.basis[k] = the shares { here, elsewhere, none } of track k's own output (given for the
--            tracks with files; a bus's from its inputs by power, then degraded by its gain's own
--            shares o.gbasis[b], nil where its gain is exact: no FX);
--   o.meas[k] (optional) = shares as o.basis, carried the same way in the same pass (step 9b
--            review: the share its meters measured; an input without one counts as not measured;
--            a second pass of its own cost 0.3-0.6 ms at p95 on 224 tracks).
-- o.pass, o.outm, o.sides, o.tap, o.rho as HD.propagate. Returns own and basis.
function HD.fill(n, own, dry, way, bus, o)
  local pass, outm, tap, rho = o.pass, o.outm or {}, o.tap or {}, o.rho or {}
  local gain, basis, gb = o.gain or {}, o.basis or {}, o.gbasis or {}
  local meas = o.meas
  local ins = {}
  for k = 1, n do
    local d = dry[k]
    if d and bus[d] and (not pass or pass[k]) then
      ins[d] = ins[d] or {}
      ins[d][#ins[d] + 1] = { k, way[k], (outm[k] or 0) ~= 0 }
    end
  end
  for _, s in ipairs(o.sides or {}) do
    if bus[s.dst] and s.pass ~= false then
      ins[s.dst] = ins[s.dst] or {}
      ins[s.dst][#ins[s.dst] + 1] = { s.src, s.M, s.pre }
    end
  end
  local state = {}
  local function out(k)
    if state[k] or not ins[k] then return end -- done, without inputs, or a loop in the routing
    state[k] = true
    local il, ir, w, wm = 0, 0, { 0, 0, 0 }, { 0, 0, 0 }
    for _, e in ipairs(ins[k]) do
      local i, A, pre = e[1], e[2], e[3]
      out(i)
      local p = pre and tap[i] or own[i]
      if p and p[1] + p[2] > 0 then
        local pl, pr, pc = p[1], p[2], (not pre and rho[i] or 0) * sqrt(p[1] * p[2])
        if A then pl, pr, pc = HD.cov(A, pl, pr, pc) end
        local ql, qr = HD.cov(bus[k].M, pl, pr, pc)
        il, ir = il + ql, ir + qr
        local v = basis[i] or { 1, 0, 0 }
        for j = 1, 3 do w[j] = w[j] + v[j] * (ql + qr) end
        if meas then
          local m = meas[i] or { 0, 1, 0 }
          for j = 1, 3 do wm[j] = wm[j] + m[j] * (ql + qr) end
        end
      end
    end
    local g = gain[k] or 1
    local base = own[k]
    local bl, br = base and base[1] or 0, base and base[2] or 0
    local pin = (il + ir) * g
    if pin + bl + br <= 0 then return end
    local pb = bl + br
    local function blend(v, vb)
      local vin = il + ir > 0 and HD.degrade({ v[1] / (il + ir), v[2] / (il + ir), v[3] / (il + ir) }, gb[k]) or { 0, 0, 0 }
      return { (vb[1] * pb + vin[1] * pin) / (pb + pin), (vb[2] * pb + vin[2] * pin) / (pb + pin), (vb[3] * pb + vin[3] * pin) / (pb + pin) }
    end
    own[k] = { bl + il * g, br + ir * g }
    basis[k] = blend(w, basis[k] or { 1, 0, 0 })
    if meas then meas[k] = blend(wm, meas[k] or { 0, 1, 0 }) end
  end
  for b in pairs(ins) do out(b) end
  return own, basis
end

-- Where each heard level comes from: a track's own output's shares, degraded by the FX gain of
-- every bus on its main path to the master (gbasis[b], nil where exact).
function HD.carry_basis(n, basis, dry, gbasis)
  local hb = {}
  for k = 1, n do
    local v = basis[k]
    if v then
      local x, guard = dry[k], 0
      while x and x > 0 and guard < 64 do v, x, guard = HD.degrade(v, gbasis[x]), dry[x], guard + 1 end
      hb[k] = v
    end
  end
  return hb
end

return HD
