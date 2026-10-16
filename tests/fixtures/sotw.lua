-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- "sotw" (step 10b): a second song for the meters' crest model and the stage's depth. Actions,
-- "South Of The Water" (Cambridge-MT's multitrack library, for education only: the files stay
-- where the owner put them, L.env().media2, and are never copied into the repository), 96 s from
-- 1:30, rebuilt with folders, pans spread wide, REAPER's own FX (compression on snare, bass and
-- lead vocal, EQ cutting the guitars' lows, a widened piano) and reverb and delay returns.
-- Sections (regions): chorus 2, bridge, break (piano and a reversed cymbal only), last chorus.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "lib.lua")

local OFFSET, LEN = 90, 96   -- song time 90-186 s becomes project time 0-96 s

return function(P)
  local E = L.env()
  if not E.media2 then error(L.no_path("multitrack for the sotw fixture", "media2", "RFV_MEDIA2"), 0) end
  local function src(t, file) L.item(t, E.media2 .. L.SEP .. file .. ".wav", 0, LEN, OFFSET) end
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

  -- Drums
  local drums = L.track(P, "Drums", 1); comp(drums, -20, 2, 2)
  src(L.track(P, "Kick"), "01_KickTrigger")
  local sn = L.track(P, "Snare"); src(sn, "02_Snare"); comp(sn, -22, 4, 3)
  src(L.track(P, "Overheads"), "03_Overheads")
  src(L.track(P, "Tom 1", 0, { pan = -0.3 }), "04_Tom1")
  src(L.track(P, "Tom 2", 0, { pan = 0.4 }), "05_Tom2")
  src(L.track(P, "Tambourine", 0, { pan = 0.6 }), "06_Tambourine")
  src(L.track(P, "Rev cymbal"), "07_RevCymbal")
  src(L.track(P, "Sprinkles", -1), "08_Sprinkles")                  -- closes Drums
  -- Bass
  local bass = L.track(P, "Bass"); src(bass, "09_Bass"); comp(bass, -26, 4, 5)
  -- Guitars: doubles spread wide, the bus cutting their lows
  local gtrs = L.track(P, "Guitars", 1); eq(gtrs, "Low Shelf", 200, -5)
  src(L.track(P, "Gtr 2", 0, { pan = -0.8 }), "11_ElecGtr2")
  src(L.track(P, "Gtr 3", 0, { pan = 0.8 }), "12_ElecGtr3")
  src(L.track(P, "Gtr 4", 0, { pan = -1 }), "13_ElecGtr4")
  src(L.track(P, "Gtr 5", 0, { pan = 1 }), "14_ElecGtr5")
  src(L.track(P, "Gtr 6", 0, { pan = -0.5 }), "15_ElecGtr6")
  src(L.track(P, "Gtr 7", 0, { pan = 0.5 }), "16_ElecGtr7")
  src(L.track(P, "Acoustic L", 0, { pan = -0.6 }), "17_AcGtr")
  src(L.track(P, "Acoustic R", -1, { pan = 0.6 }), "18_AcGtr")    -- closes Guitars
  -- Piano, widened
  local piano = L.track(P, "Piano", 0, { mode = 5, width = 0.8 }); src(piano, "19_Piano")
  local w = L.fx(piano, "JS:Stereo Width"); L.set(piano, w, "Width Boost (dB)", 4)
  -- Vocals
  local vox = L.track(P, "Vocals", 1)
  local lv = L.track(P, "Lead vox"); src(lv, "20_LeadVox"); comp(lv, -22, 3, 4); eq(lv, "Band 3", 2500, 3)
  src(L.track(P, "Lead double", 0, { vol = 0.5 }), "21_LeadVoxDT")
  local bvs = L.track(P, "Backing vox", 1)
  local pans = { -0.7, 0.7, -0.4, 0.4, -0.9, 0.9, -0.2, 0.2, 0 }
  for i, pan in ipairs(pans) do
    src(L.track(P, "BV " .. i, i == #pans and -2 or 0, { pan = pan }), ("%02d_BackingVox%d"):format(21 + i, i))
  end                                                                -- the last closes BVs and Vocals
  -- Returns
  L.track(P, "Returns", 1)
  local verb = L.track(P, "Reverb"); local rv = L.fx(verb, "ReaVerbate"); L.set(verb, rv, "Dry", -1e6); L.set(verb, rv, "Wet", 0)
  local dly = L.track(P, "Delay", -1); local dl = L.fx(dly, "ReaDelay"); L.set(dly, dl, "Dry", -1e6); L.set(dly, dl, "Wet", 0)
  L.send(sn, verb, 0.3); L.send(lv, verb, 0.2); L.send(lv, dly, 0.15); L.send(bvs, verb, 0.35); L.send(piano, verb, 0.25)
  -- Sections
  L.region(P, "Chorus 2", 0, 36)
  L.region(P, "Bridge", 36, 60)
  L.region(P, "Break", 60, 66)
  L.region(P, "Last chorus", 66, 96)
  return { length = LEN, heard = true }
end
