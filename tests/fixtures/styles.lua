-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- "styles": the routing habits the role classifier (roadmap step 4) must read, side by side
-- in one project, with REAPER's own FX only. Track names say what each case is; the
-- classifier never reads them. Expected roles live with the classifier tests (step 4.2).
--
--   folder group             Drums: Kick, Snare, Room (muted), Ghost SC, OH (polarity flipped)
--   parent send to 3/4       Ghost SC reaches its folder on channels 3/4 (a sidechain by parent)
--   sidechain send           Kick -> Bass channels 3/4 (Bass has 4 channels)
--   organizational folder    VOCALS holds tracks whose master/parent send is off
--   send group               Lead, Double -> Vox bus
--   pass-through chain       Harmony -> Type BV -> Group BV -> Vox bus
--   return                   Verb, fed by Kick, Snare (muted send), Lead, Double (mono, pre-FX)
--   parallel at equal level  Gtr L/R -> Gtr bus and Gtr par, both at 0 dB
--   MIDI to an instrument    Keys MIDI -> Keys synth (MIDI-only send)
--   extra instrument outputs Keys synth channels 3/4 -> Keys out
--   live input               Live mic: armed, monitoring, input 1 (fader at -inf: no sound)
--   folder with own items    Perc (item) holds Shaker
--   hardware output only     Click to phones: master send off, one hardware output
--   empty track              Empty
--   silent instruments       Pad offline, Pad bypassed, Synth chain off (track FX disabled)
--   JS generator             Tone JS: MIDI items + JS Tone Generator (not seen as an instrument)
--   MIDI without instrument  MIDI only
--   takes                    Takes: MIDI take with an active audio take, an audio item whose
--                            active take is empty, a muted item (counts: audio 1, MIDI 0)
--   nested folders           Outer > Inner > Deep (closes two levels at once)
--   dead-end folder          STRINGS has its own send off; Choir inside keeps REAPER's default
--                            parent send on and reaches the mix by a send to Vox bus

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "lib.lua")

local function set(tr, k, v) reaper.SetMediaTrackInfo_Value(tr, k, v) end
local function sset(tr, k, key, v) reaper.SetTrackSendInfo_Value(tr, 0, k, key, v) end

return function(P)
  local S = L.env().signals .. L.SEP
  local SINE, ST, NOISE = S .. "sine1k_m12.wav", S .. "st_500L_3kR.wav", S .. "noise_m20.wav"
  local function audio(tr, f) L.item(tr, f or SINE, 0, 10) return tr end
  local function synth(name, how)
    local tr = L.track(P, name)
    L.midi_chord(tr, 0, 10, { 48, 55, 64 })
    local fx = L.fx(tr, how == "js" and "JS:Tone Generator" or "ReaSynth")
    if how == "offline" then reaper.TrackFX_SetOffline(tr, fx, true)
    elseif how == "bypass" then reaper.TrackFX_SetEnabled(tr, fx, false)
    elseif how == "chainoff" then set(tr, "I_FXEN", 0) end
    return tr
  end

  -- Folder group
  L.track(P, "Drums", 1)
  local kick = audio(L.track(P, "Kick"), NOISE)
  local snare = audio(L.track(P, "Snare"), NOISE)
  local room = audio(L.track(P, "Room (muted)")); set(room, "B_MUTE", 1)
  local ghost = audio(L.track(P, "Ghost SC to parent 3/4")); set(ghost, "C_MAINSEND_OFFS", 2); set(ghost, "C_MAINSEND_NCH", 2)
  local oh = audio(L.track(P, "OH (polarity)", -1), ST); set(oh, "B_PHASE", 1)

  local bass = audio(L.track(P, "Bass 4ch")); set(bass, "I_NCHAN", 4)

  -- Organizational folder, send group, pass-through chain
  L.track(P, "VOCALS (organizing)", 1)
  local lead = audio(L.track(P, "Lead", 0, { mainsend = false }))
  local double = audio(L.track(P, "Double", 0, { mainsend = false }))
  local harm = audio(L.track(P, "Harmony", 0, { mainsend = false }))
  local typebv = L.track(P, "Type BV", 0, { mainsend = false })
  local groupbv = L.track(P, "Group BV", -1, { mainsend = false })
  local voxbus = L.track(P, "Vox bus")
  local verb = L.track(P, "Verb")

  -- Parallel buses at the same level
  local gl = audio(L.track(P, "Gtr L", 0, { mainsend = false, pan = -1 }))
  local gr = audio(L.track(P, "Gtr R", 0, { mainsend = false, pan = 1 }))
  local gbus = L.track(P, "Gtr bus")
  local gpar = L.track(P, "Gtr par")

  -- MIDI to an instrument, extra outputs
  local kmidi = L.track(P, "Keys MIDI")
  L.midi_chord(kmidi, 0, 10, { 60, 64, 67 })
  local ksyn = L.track(P, "Keys synth 4ch"); L.fx(ksyn, "ReaSynth"); set(ksyn, "I_NCHAN", 4)
  local kout = L.track(P, "Keys out 3/4")

  -- Live input: armed and monitoring, fader at -inf so nothing reaches the speakers
  local live = L.track(P, "Live mic", 0, { vol = 0 })
  set(live, "I_RECINPUT", 0); set(live, "I_RECMON", 1); set(live, "I_RECARM", 1)

  -- Folder with its own items
  audio(L.track(P, "Perc (folder with items)", 1), NOISE)
  audio(L.track(P, "Shaker", -1), NOISE)

  -- Hardware output only
  local click = audio(L.track(P, "Click to phones", 0, { mainsend = false }))
  reaper.CreateTrackSend(click, nil)

  L.track(P, "Empty")
  synth("Pad offline", "offline")
  synth("Pad bypassed", "bypass")
  synth("Synth chain off", "chainoff")
  synth("Tone JS", "js")
  L.midi_chord(L.track(P, "MIDI only"), 0, 10, { 72 })

  -- Takes
  local takes = L.track(P, "Takes")
  local a = reaper.CreateNewMIDIItemInProj(takes, 0, 2, false)
  local a2 = reaper.AddTakeToMediaItem(a)
  reaper.SetMediaItemTake_Source(a2, reaper.PCM_Source_CreateFromFile(SINE))
  reaper.SetActiveTake(a2)
  local b = L.item(takes, SINE, 3, 2)
  reaper.SetActiveTake(reaper.AddTakeToMediaItem(b))
  local c = L.item(takes, SINE, 6, 2)
  reaper.SetMediaItemInfo_Value(c, "B_MUTE", 1)

  -- Nested folders closing two levels at once
  L.track(P, "Outer", 1)
  L.track(P, "Inner", 1)
  audio(L.track(P, "Deep", -2))

  -- An organizing folder with its own send off; the child keeps its parent send on
  L.track(P, "STRINGS (send off)", 1, { mainsend = false })
  local choir = audio(L.track(P, "Choir", -1))

  -- Sends (after all tracks exist)
  local k = L.send(kick, bass, 0.5); sset(kick, k, "I_DSTCHAN", 2)              -- sidechain 3/4
  L.send(kick, verb, 0.2)
  k = L.send(snare, verb, 0.2); sset(snare, k, "B_MUTE", 1)                     -- muted send
  k = L.send(lead, voxbus, 1); sset(lead, k, "I_MIDIFLAGS", 31)                 -- MIDI off
  L.send(lead, verb, 0.3)
  L.send(double, voxbus, 1)
  k = L.send(double, verb, 0.25, { mode = 1 }); sset(double, k, "B_MONO", 1)    -- mono, pre-FX
  L.send(harm, typebv, 1)
  L.send(typebv, groupbv, 1, { mode = 3 })                                      -- post-FX pre-fader
  L.send(groupbv, voxbus, 1)
  L.send(choir, voxbus, 1)
  L.send(gl, gbus, 1); L.send(gl, gpar, 1)
  L.send(gr, gbus, 1); L.send(gr, gpar, 1)
  k = L.send(kmidi, ksyn, 1); sset(kmidi, k, "I_SRCCHAN", -1)                   -- MIDI only
  k = L.send(ksyn, kout, 1); sset(ksyn, k, "I_SRCCHAN", 2)                      -- outputs 3/4
  k = L.send(voxbus, verb, 0.1); sset(voxbus, k, "I_SRCCHAN", 1024); sset(voxbus, k, "B_PHASE", 1) -- mono ch 1, flipped
  return { length = 10 }
end
