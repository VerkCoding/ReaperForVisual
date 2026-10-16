-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- "band": the OurGoodWolf multitrack (96 s from 1:40) rebuilt with folders, sub-buses,
-- returns, the owner's pans and REAPER's own FX doing what makes a stage hard to read:
-- EQ that brightens cymbals, compression, bus gain (+6 dB, like the SSL inputs of the real
-- mix), a stereo widener in the piano's FX chain (track FX run before the track's pan), and
-- reverb and delay returns.
-- Sections (regions): verse 2, backing vocals, shaker, ending.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "lib.lua")

local OFFSET, LEN = 100, 96   -- song time 100-196 s becomes project time 0-96 s

return function(P)
  local E = L.env()
  if not E.media then error(L.no_path("multitrack for the band fixture", "media", "RFV_MEDIA"), 0) end
  local function src(t, file) L.item(t, E.media .. L.SEP .. file .. ".wav", 0, LEN, OFFSET) end
  local function eq(t, band, freq, gain)
    local fx = L.fx(t, "ReaEQ")
    L.set(t, fx, "Freq-" .. band, freq); L.set(t, fx, "Gain-" .. band, gain)
    return fx
  end
  local function comp(t, thresh, ratio, makeup)
    local fx = L.fx(t, "ReaComp")
    L.set(t, fx, "Threshold", thresh); L.set(t, fx, "Ratio", ratio)
    if makeup then local v = L.fx(t, "JS:Utility/volume"); L.set(t, v, "Adjustment (dB)", makeup) end
  end
  local function gain(t, db) local v = L.fx(t, "JS:Utility/volume"); L.set(t, v, "Adjustment (dB)", db) end

  -- Drums
  local drums = L.track(P, "Drums", 1); gain(drums, 6); comp(drums, -18, 2)
  L.track(P, "Kick", 1)
  local k1 = L.track(P, "Kick in"); src(k1, "01_KickMic1"); eq(k1, "Low Shelf", 80, 4)
  local k2 = L.track(P, "Kick out", -1); src(k2, "02_KickMic2")
  L.track(P, "Snare", 1)
  local sn = L.track(P, "Snare top"); src(sn, "03_Snare1"); comp(sn, -20, 4, 4)
  local sn2 = L.track(P, "Snare up"); src(sn2, "04_Snare2Up")
  local sn3 = L.track(P, "Snare down", -1); src(sn3, "05_Snare2Down")
  L.track(P, "Cymbals", 1)
  local hh = L.track(P, "Hi-hat", 0, { pan = -0.35 }); src(hh, "06_HiHat"); eq(hh, "High Shelf 4", 6000, 8)
  local ride = L.track(P, "Ride", 0, { pan = 0.65 }); src(ride, "07_Ride"); eq(ride, "High Shelf 4", 5000, 9)
  local oh = L.track(P, "Overhead", -1); src(oh, "08_Overhead")
  local rooms = L.track(P, "Rooms", 1); comp(rooms, -30, 8, 8)
  src(L.track(P, "Room 1"), "09_DrumsRoom1")
  src(L.track(P, "Room 2", 0, { pan = -1 }), "10_DrumsRoom2")
  src(L.track(P, "Room 3", 0, { pan = 0.5 }), "11_DrumsRoom3")
  src(L.track(P, "Room 4", -2, { pan = 1 }), "12_DrumsRoom4")       -- closes Rooms and Drums
  -- Percussion
  src(L.track(P, "Shaker", 0, { pan = 0.55 }), "13_Shaker")
  -- Bass
  local bass = L.track(P, "Bass", 1); comp(bass, -24, 4, 6)
  src(L.track(P, "Bass amp"), "14_BassAmp")
  src(L.track(P, "Bass DI", -1), "15_BassDI")
  -- Guitars and keys
  local g1 = L.track(P, "Gtr 1", 0, { mode = 5, pan = -0.7, width = 0.3 }); src(g1, "16_ElecGtr1"); eq(g1, "Low Shelf", 150, -6)
  -- a fast limiter: lowers the crest, as heavy limiting in a real mix does
  local g2 = L.track(P, "Gtr 2", 0, { pan = 0.7 }); src(g2, "17_ElecGtr2")
  local lim = L.fx(g2, "ReaComp")
  L.set(g2, lim, "Threshold", -30); L.set(g2, lim, "Ratio", 20); L.set(g2, lim, "Attack", 0); L.set(g2, lim, "Release", 20)
  gain(g2, 10)
  -- a virtual instrument: audible on the meters, silent to an audio accessor
  local pad = L.track(P, "Synth pad", 0, { pan = -0.4 }); L.fx(pad, "ReaSynth"); L.midi_chord(pad, 0, LEN, { 52, 59, 64 })
  gain(pad, -12)
  local piano = L.track(P, "Piano", 0, { mode = 5, pan = -0.3, width = 0.6 }); src(piano, "18_Piano")
  local w = L.fx(piano, "JS:Stereo Width"); L.set(piano, w, "Width Boost (dB)", 6)
  -- Vocals
  local vox = L.track(P, "Vocals", 1); gain(vox, 3)
  local lv = L.track(P, "Lead vox"); src(lv, "19_LeadVox1"); comp(lv, -24, 4, 6); eq(lv, "Band 3", 3000, 4)
  src(L.track(P, "Lead octave"), "20_LeadVox2")
  local bvs = L.track(P, "Backing vox", 1)
  local bv = {}
  for i, pan in ipairs({ -0.3, -0.65, 0.65, 0.3, -0.3 }) do
    bv[i] = L.track(P, "BV " .. i, i == 5 and -2 or 0, { pan = pan }); src(bv[i], ("%02d_BackingVox%d"):format(20 + i, i))
  end
  -- Returns
  local fxf = L.track(P, "Returns", 1)
  local verb = L.track(P, "Reverb"); local rv = L.fx(verb, "ReaVerbate"); L.set(verb, rv, "Dry", -1e6); L.set(verb, rv, "Wet", 0)
  local dly = L.track(P, "Delay", -1); local dl = L.fx(dly, "ReaDelay"); L.set(dly, dl, "Dry", -1e6); L.set(dly, dl, "Wet", 0)
  L.send(sn, verb, 0.3); L.send(lv, verb, 0.25); L.send(lv, dly, 0.2); L.send(bvs, verb, 0.3)
  -- Sections
  L.region(P, "Verse 2", 2, 30)
  L.region(P, "Backing vocals", 30, 60)
  L.region(P, "Shaker", 60, 78)
  L.region(P, "Ending", 78, 96)
  return { length = LEN }
end
