-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Spectra for Y and width (roadmap step 7): what a track's files sound like, read through its
-- audio accessor (before its FX, fader and pan), and how tracks add up into buses and groups.
--
-- Y is the spectral centroid as the ground truth defines it (DESIGN.md, "Reference
-- definitions"): the power-weighted mean of log2 f over 20 Hz - 20 kHz, from 2,048-point
-- periodic Hann windows, left and right powers added. Width is the left/right correlation.
--
-- A stats vector s = { PL, PR, C, ML, MR, MC, n } holds, over 20 Hz - 20 kHz, the left, right
-- and cross powers, the same three weighted by log2 of each bin's frequency, and how many windows
-- went into it. Because the centroid is a ratio of sums, these add up across windows, blocks and
-- tracks, and pass through a pan matrix exactly (step 7 research: 1/3-octave bands alone cost
-- 0.05 octave; the moments cost nothing).
--
-- One complex FFT carries both channels: with z = L + iR, a = Z(k), b = Z(N-k), the left and
-- right powers of bin k are (|a|^2+|b|^2 +- 2Re(ab))/4 and the cross power Im(ab)/2, whatever the
-- FFT's sign convention. ~0.4 ms a window on the owner's machine (read 0.15, FFT 0.017, bins).

local SP = {}
SP.N, SP.SR = 2048, 48000
SP.F_LO, SP.F_HI = 20, 20000
-- A window's PL (or PR) over a channel of mean square 1, in band: sum over the positive bins of
-- |X(k)|^2 = N/2 x sum of w^2 = N/2 x 3N/8 (Hann). Divided by it and by the windows counted, a
-- stats vector's powers are the files' mean squares, as the meters and the truth measure them
-- (step 9 research: 58.92 dB on the band fixture's tracks without FX, 58.96 by this formula).
SP.SCALE = 3 * SP.N * SP.N / 16

-- An analyser: the window (interleaved for both channels), a buffer and the bins it uses.
function SP.new(n, sr)
  local an = { N = n or SP.N, SR = sr or SP.SR }
  local N = an.N
  local w = {}
  for i = 0, N - 1 do
    local v = 0.5 - 0.5 * math.cos(2 * math.pi * i / N)
    w[2 * i + 1], w[2 * i + 2] = v, v
  end
  an.win = reaper.new_array(w)
  an.buf = reaper.new_array(2 * N)
  an.k0 = math.ceil(SP.F_LO * N / an.SR)
  an.k1 = math.min(math.floor(SP.F_HI * N / an.SR), N // 2 - 1)
  an.lg = {}
  for k = an.k0, an.k1 do an.lg[k] = math.log(k * an.SR / N, 2) end
  an.len = N / an.SR -- seconds a window spans
  return an
end

function SP.zero() return { 0, 0, 0, 0, 0, 0, 0 } end

-- Read one window starting at t (project seconds) through accessor acc and add it to s.
-- Returns "audio", "silent" (samples, all zero in the band) or "none" (nothing there).
function SP.window(an, acc, t, s)
  local N, buf = an.N, an.buf
  if reaper.GetAudioAccessorSamples(acc, an.SR, 2, t, N, buf) ~= 1 then return "none" end
  buf.multiply(an.win)
  buf.fft(N, true)
  local k0, k1, lg = an.k0, an.k1, an.lg
  local m = k1 - k0 + 1
  local za = buf.table(2 * k0 + 1, 2 * m)       -- Z(k0) .. Z(k1)
  local zb = buf.table(2 * (N - k1) + 1, 2 * m) -- Z(N-k1) .. Z(N-k0)
  local PL, PR, C, ML, MR, MC = 0, 0, 0, 0, 0, 0
  for i = 0, m - 1 do
    local ar, ai = za[2 * i + 1], za[2 * i + 2]
    local j = m - 1 - i -- Z(N-k) for k = k0 + i
    local br, bi = zb[2 * j + 1], zb[2 * j + 2]
    local aa, bb = ar * ar + ai * ai, br * br + bi * bi
    local re, im = ar * br - ai * bi, ar * bi + ai * br
    local l, r, c = (aa + bb + 2 * re) / 4, (aa + bb - 2 * re) / 4, im / 2
    local g = lg[k0 + i]
    PL, PR, C = PL + l, PR + r, C + c
    ML, MR, MC = ML + l * g, MR + r * g, MC + c * g
  end
  s[7] = s[7] + 1
  if PL + PR <= 0 then return "silent" end
  s[1], s[2], s[3], s[4], s[5], s[6] = s[1] + PL, s[2] + PR, s[3] + C, s[4] + ML, s[5] + MR, s[6] + MC
  return "audio"
end

-- dst += w * src (w defaults to 1); returns dst.
function SP.add(dst, src, w)
  w = w or 1
  for i = 1, 6 do dst[i] = dst[i] + w * src[i] end
  dst[7] = dst[7] + src[7]
  return dst
end

function SP.power(s) return s[1] + s[2] end

-- Through an amplitude matrix A = { ll, rl, lr, rr } (rfv_heard.lua's form: out L = ll*L + rl*R,
-- out R = lr*L + rr*R): the covariance of each band passes exactly. Returns a new vector.
local function cov(A, l, r, c)
  local a, b, d, e = A[1], A[2], A[3], A[4]
  return a * a * l + b * b * r + 2 * a * b * c,
         d * d * l + e * e * r + 2 * d * e * c,
         a * d * l + b * e * r + (a * e + b * d) * c
end
function SP.through(A, s)
  local PL, PR, C = cov(A, s[1], s[2], s[3])
  local ML, MR, MC = cov(A, s[4], s[5], s[6])
  return { PL, PR, C, ML, MR, MC, s[7] }
end

-- Y in Hz, or nil without sound.
function SP.y(s)
  local p = s[1] + s[2]
  if p <= 0 then return nil end
  return 2 ^ ((s[4] + s[5]) / p)
end

-- Left/right correlation (-1 .. 1), or nil without sound in either channel. A channel that
-- holds nothing reads 1 (a mono part is one point), as the ground truth does.
function SP.corr(s)
  if s[1] <= 0 and s[2] <= 0 then return nil end
  if s[1] <= 0 or s[2] <= 0 then return 1 end
  local c = s[3] / math.sqrt(s[1] * s[2])
  return math.max(-1, math.min(1, c))
end

-- What a track sounds like at its output, from the files and the routing, for every track at
-- once (roadmap step 7, decision 3). For track k:
--   src[k]   its items' stats over the readout window (nil: none, or not read yet)
--   M[k]     its own pan matrix with every volume stage (rfv_heard.lua's HD.matrix)
--   P[k]     the power its meter measures at its output now (0: silent; nil: not measured, as
--            while stopped, and then its files' own power after its matrix stands in)
--   fx[k]    true when it has active FX (they act unseen)
--   dry[k], way[k], pass[k]   its main path, as for HD.propagate; sides: other audio sends
--            { src, dst, M, pass }
--   blind[k] true when it plays MIDI (its files say nothing of its sound), for when nothing is
--            measured
--   cover[k] the share of its own files' window read so far (nil: all of it)
-- A track whose files are silent in the window is silent when its meter is (no Y, nothing
-- unknown), and unknown when its meter sounds anyway (step 7 review of the band run: a shaker
-- that plays in one section only was reported unknown everywhere else).
-- Its input is its items plus what its inputs bring (each scaled to the power it measures,
-- through the send's matrix); its output is that through its own matrix. Returns per track
--   S[k]  the stats at its output (shape only; nil when nothing of it is known)
--   u[k]  the share of its power whose spectrum is unknown (a virtual instrument, a live input,
--         a part not read yet), 0 .. 1
--   f[k]  the share that passed FX we cannot hear (its own, or a bus's on the way), 0 .. 1
--   r[k]  the share still to be read: its own files' unread share, or more where what its
--         inputs bring (by the power each measures) is unread; a bus or a return has no files
--         of its own, so this says whether its Y is still settling (step 8 review)
function SP.compose(n, src, M, P, fx, dry, way, pass, sides, blind, cover)
  local ins = {}
  for k = 1, n do
    local d = dry[k]
    if d and d > 0 and (not pass or pass[k] ~= false) then
      ins[d] = ins[d] or {}
      table.insert(ins[d], { k, way[k] })
    end
  end
  for _, sd in ipairs(sides or {}) do
    if sd.pass ~= false and sd.dst and sd.dst > 0 then
      ins[sd.dst] = ins[sd.dst] or {}
      table.insert(ins[sd.dst], { sd.src, sd.M })
    end
  end
  local S, u, f, r, busy = {}, {}, {}, {}, {}
  local function gain(A) -- power gain of a matrix on a centred, uncorrelated signal
    if not A then return 1 end
    return (A[1] * A[1] + A[2] * A[2] + A[3] * A[3] + A[4] * A[4]) / 2
  end
  local function out(k)
    if u[k] ~= nil then return end
    if busy[k] then u[k], f[k], r[k] = 1, 0, 0; return end -- a loop in the routing
    busy[k] = true
    local Sin = src[k] and SP.add(SP.zero(), src[k]) or nil
    local known, unknown, unseen = Sin and SP.power(Sin) or 0, 0, 0
    local pending, brought = 0, 0 -- what its inputs bring: unread, and in all (powers)
    for _, e in ipairs(ins[k] or {}) do
      local i, A = e[1], e[2]
      out(i)
      -- the power it measures; not measured (stopped: meters are silent), the files' own
      local p = P[i]
      if p == nil then p = S[i] and SP.power(S[i]) or 0 end
      if p > 0 then
        local share_known = 1 - u[i]
        if S[i] and share_known > 0 and SP.power(S[i]) > 0 then
          -- its shape scaled to the power it measures (the known part), then the way in
          local w = share_known * p / SP.power(S[i])
          local x = A and SP.through(A, S[i]) or S[i]
          Sin = SP.add(Sin or SP.zero(), x, w)
          known = known + w * SP.power(x)
        end
        unknown = unknown + u[i] * p * gain(A)
        unseen = unseen + f[i] * p * gain(A)
        pending = pending + r[i] * p * gain(A)
        brought = brought + p * gain(A)
      end
    end
    -- still to read: its own files', or its inputs' by power, whichever is more (a bus seldom
    -- has items of its own)
    local own_r = cover and cover[k] and 1 - cover[k] or 0
    r[k] = math.max(own_r, brought > 0 and pending / brought or 0)
    busy[k] = nil
    if Sin and SP.power(Sin) > 0 then
      S[k] = SP.through(M[k] or { 1, 0, 0, 1 }, Sin)
    end
    local total = known + unknown
    if total <= 0 then
      -- nothing coming in: its files alone. Without sound in them, it is silent if its meter is
      -- (nothing unknown), and unknown if its meter sounds (a virtual instrument, a live input,
      -- its FX's tail); not measured (stopped), unknown if it plays MIDI (blind)
      if S[k] then u[k] = 0
      elseif P[k] ~= nil then u[k] = P[k] > 0 and 1 or 0
      else u[k] = blind and blind[k] and 1 or 0 end
      f[k] = (S[k] and fx[k]) and 1 or 0
    else
      u[k] = unknown / total
      f[k] = fx[k] and 1 or math.min(1, unseen / total)
    end
  end
  for k = 1, n do out(k) end
  return S, u, f, r
end

-- Several parts as one (a display group): their shapes, each scaled to the power w[i] it brings.
-- Returns S, u, f, r as SP.compose does for one track (r: by power, or the parts' mean when
-- none sounds).
function SP.combine(parts)
  local S, known, unknown, unseen, pending, weight, rsum = nil, 0, 0, 0, 0, 0, 0
  for _, p in ipairs(parts) do
    local w = p.w or 0
    rsum = rsum + (p.r or 0)
    if w > 0 then
      local share = 1 - (p.u or 1)
      if p.S and share > 0 and SP.power(p.S) > 0 then
        S = SP.add(S or SP.zero(), p.S, share * w / SP.power(p.S))
        known = known + share * w
      end
      unknown = unknown + (p.u or 1) * w
      unseen = unseen + (p.f or 0) * w
      pending = pending + (p.r or 0) * w
      weight = weight + w
    end
  end
  local r = weight > 0 and pending / weight or (#parts > 0 and rsum / #parts or 0)
  local total = known + unknown
  if total <= 0 then return S, S and 0 or 1, 0, r end
  return S, unknown / total, math.min(1, unseen / total), r
end

return SP
