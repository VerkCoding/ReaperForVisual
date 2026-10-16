-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- "calib": synthetic signals whose true stage is known by arithmetic, so the ground-truth
-- ruler can be checked against theory. Needs tools/make_signals.py to have run.
--
-- Expected at each track's output (balance pan with 0 dB law; stereo mode = width, then
-- balance). Sine peak 0.25 = -15.05 dB RMS per channel. Level = 10*log10(L power + R power).
--   sine pan +0.5             amplitudes L 0.5, R 1    azimuth +10.89 deg   level -14.08 dB
--   sine fader -6             L = R                    azimuth   0          level -18.06 dB
--   sine stereo -0.702 w0.3   L 1, R 0.298             azimuth -17.34 deg   level -14.68 dB
--   st 500L 3kR               uncorrelated             azimuth   0          level -12.04 dB, correlation 0,
--                                                      centroid 1224.7 Hz (equal power at 500 and 3000)
--   noise -20                 white, RMS 0.1           azimuth   0          level -16.99 dB, centroid about
--                                                      7.4 kHz (log-frequency mean over 20 Hz-20 kHz)
--   st pan +0.5               500 Hz left x0.5         azimuth +10.89 deg   level -14.08 dB, centroid 2096.7 Hz
--                             (balance lowers only the far channel of a stereo source)
--   noise anti-phase          right = -left            azimuth   0          level -16.99 dB, correlation -1
--   synth chord               ReaSynth, MIDI           heard (not silent); no theory for its level
--   sine pan sweep            envelope -1 -> +1 = pan  whole: azimuth 0, level -13.80 dB; each half
--                             right -> left over 20 s  8.80 deg off centre; 400 ms blocks span about +-21 deg

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "lib.lua")

return function(P)
  local E = L.env()
  local S = E.signals .. L.SEP
  L.item(L.track(P, "sine pan +0.5", 0, { pan = 0.5 }), S .. "sine1k_m12.wav", 0, 20)
  L.item(L.track(P, "sine fader -6", 0, { vol = 0.5 }), S .. "sine1k_m12.wav", 0, 20)
  L.item(L.track(P, "sine stereo -0.702 w0.3", 0, { mode = 5, pan = -0.702, width = 0.3 }), S .. "sine1k_m12.wav", 0, 20)
  L.item(L.track(P, "st 500L 3kR", 0), S .. "st_500L_3kR.wav", 0, 20)
  L.item(L.track(P, "noise -20", 0), S .. "noise_m20.wav", 0, 20)
  -- balance pan on a stereo source only lowers the far channel
  L.item(L.track(P, "st pan +0.5", 0, { pan = 0.5 }), S .. "st_500L_3kR.wav", 0, 20)
  L.item(L.track(P, "noise anti-phase", 0), S .. "noise_antiphase.wav", 0, 20)
  local syn = L.track(P, "synth chord", 0)
  L.fx(syn, "ReaSynth")
  L.midi_chord(syn, 0, 20, { 48, 55, 64 })
  local sweep = L.track(P, "sine pan sweep", 0)
  L.item(sweep, S .. "sine1k_m12.wav", 0, 20)
  L.pan_sweep(sweep, 0, 20, -1, 1)
  L.region(P, "first half", 0, 10)
  L.region(P, "second half", 10, 20)
  return { length = 20 }
end
