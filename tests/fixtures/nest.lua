-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- "nest": where a track is HEARD once its parent buses have panned it. Folder buses with
-- every pan kind (balance, stereo with width, dual, a track pan law of -3 or -6 dB, two
-- levels deep, a widener on the bus). No sends, so a render "via master" holds exactly the
-- track and its buses. Truth comes in two layers: each track's own output and how it is
-- heard at the master (tools/truth_export.lua renders both when info.heard is set).
--
-- Heard at the master, by arithmetic, with REAPER's pan as measured on 2026-10-11 (sine peak
-- 0.25 = -15.05 dB RMS per channel). Balance, 0 dB law: far side x (1 - |p|). Stereo mode:
-- width crossfeed (1+w)/2, (1-w)/2, then a stereo pan: at +p left -> (1-p) left + p/2 right,
-- right -> (1-p/2) right. Dual pan: each channel by the 0 dB law. -3 dB law: sine/cosine,
-- centre -3.0 dB. -6 dB law: linear, centre -6.0 dB.
--   a1 sine pan 0 in bus -0.5            L 1, R 0.5            -10.89 deg   -14.08 dB
--   a2 sine pan +0.5 in bus -0.5         L 0.5, R 0.5            0          -18.06 dB
--   b1 500L/3kR in stereo +0.3 w0.5      powers L .306, R .561  +4.96 deg   -15.67 dB
--   b2 sine pan -1 in stereo +0.3 w0.5   L 0.525, R 0.325       -7.74 deg   -19.24 dB
--   c1 500L/3kR in dual -0.5 / +0.5      powers 1.25 each         0         -11.07 dB
--   d1 sine in bus -3 dB law, pan +0.5   L 0.383, R 0.925      +13.44 deg   -15.04 dB
--   d2 sine in bus -6 dB law, pan 0      L = R = 0.501           0          -18.04 dB
--   e1 sine pan 0 in +0.6 inside -0.3    L 0.4, R 0.7           +8.95 deg   -16.92 dB
-- Bus F (a widener) has no theory: its truth is what REAPER renders.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "lib.lua")

return function(P)
  local S = L.env().signals .. L.SEP
  local function sine(t) L.item(t, S .. "sine1k_m12.wav", 0, 20) end
  local function st(t) L.item(t, S .. "st_500L_3kR.wav", 0, 20) end

  L.track(P, "Bus A pan -0.5", 1, { pan = -0.5 })
  sine(L.track(P, "a1 sine pan 0"))
  sine(L.track(P, "a2 sine pan +0.5", -1, { pan = 0.5 }))

  L.track(P, "Bus B stereo +0.3 w0.5", 1, { mode = 5, pan = 0.3, width = 0.5 })
  st(L.track(P, "b1 st 500L 3kR"))
  sine(L.track(P, "b2 sine pan -1", -1, { pan = -1 }))

  local c = L.track(P, "Bus C dual -0.5 +0.5", 1); L.dualpan(c, -0.5, 0.5)
  st(L.track(P, "c1 st 500L 3kR", -1))

  local d = L.track(P, "Bus D law -3 pan +0.5", 1, { pan = 0.5 }); L.panlaw(d, -3)
  sine(L.track(P, "d1 sine", -1))
  local d2 = L.track(P, "Bus D2 law -6 pan 0", 1); L.panlaw(d2, -6)
  sine(L.track(P, "d2 sine", -1))

  L.track(P, "Bus E pan -0.3", 1, { pan = -0.3 })
  L.track(P, "Bus E2 pan +0.6", 1, { pan = 0.6 })
  sine(L.track(P, "e1 sine", -2))

  local f = L.track(P, "Bus F widener", 1)
  local w = L.fx(f, "JS:Stereo Width"); L.set(f, w, "Width Boost (dB)", 6)
  sine(L.track(P, "f1 sine pan +0.5", -1, { pan = 0.5 }))

  L.region(P, "first half", 0, 10)
  L.region(P, "second half", 10, 20)
  return { length = 20, heard = true }
end
