-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The routing snapshot: everything the role classifier needs, as plain data, read from the
-- REAPER API. tools/rfv_rpp.lua makes the same snapshot from a project's .rpp text without
-- opening it, and tests/snapshot_test.lua checks that the two agree.
--
-- snap = {
--   v = 1, source = "api" | "rpp",
--   master = { guid, nchan },
--   tracks = { [k] = {            -- k = 1-based track order
--     guid, name,                 -- P_NAME, empty when unnamed
--     fdepth,                     -- I_FOLDERDEPTH: 1 opens a folder, -n closes n levels
--     parent,                     -- index of the folder parent, 0 = master (top level)
--     main, poffs, pnch,          -- master/parent send on, its channel offset and count (0 = all)
--     nchan, mute, phase,         -- channel count, track mute, polarity
--     fxon, nfx,                  -- track FX chain enabled, number of FX
--     instr,                      -- an instrument plugin that is online, enabled, chain enabled
--     audio, midi,                -- true: an unmuted item whose active take is audio; midi is
--                                 -- looked for only when there is no audio (false otherwise), so
--                                 -- a track of edited audio is read at its first item
--     hwout,                      -- hardware outputs
--     arm, recin, recmon,         -- record arm, input (-1 none, >= 4096 MIDI), monitoring mode
--   } },
--   sends = { [k] = { src, dst, mode, vol, pan, mute, mono, phase, srcchan, dstchan, midi } },
--                                 -- src/dst are track indexes; srcchan -1 = no audio;
--                                 -- channels as REAPER stores them (1024 + c = mono, 512 * n
--                                 -- for wider pairs); midi = I_MIDIFLAGS
-- }
--
-- Pan, width and volume are left out on purpose: they move with automation, so step 5 reads
-- them live. The snapshot holds structure only.

local SN = {}
SN.V = 1

local function b(x) return x ~= 0 end
local function iv(tr, k) return math.floor(reaper.GetMediaTrackInfo_Value(tr, k) + 0.5) end

-- Has the track an unmuted audio item (then stop: 5,000 items cost 17.8 ms to count), or else
-- an unmuted MIDI item?
local function item_kinds(tr)
  local m = false
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, k)
    if reaper.GetMediaItemInfo_Value(it, "B_MUTE") == 0 then
      local tk = reaper.GetActiveTake(it)
      if tk then
        if reaper.TakeIsMIDI(tk) then
          m = true
        else
          local src = reaper.GetMediaItemTake_Source(tk)
          local typ = src and reaper.GetMediaSourceType(src, "") or ""
          if typ == "SECTION" then
            local p = reaper.GetMediaSourceParent(src)
            typ = p and reaper.GetMediaSourceType(p, "") or ""
          end
          if typ ~= "" and typ ~= "EMPTY" then return true, false end
        end
      end
    end
  end
  return false, m
end

-- Snapshot of one project tab from the API. Reads only; costs ~0.01 ms per track.
function SN.from_api(proj)
  local n = reaper.CountTracks(proj)
  local index = {}
  -- Keyed by tostring: P_DESTTRACK comes back as the same pointer, so its text matches.
  for i = 0, n - 1 do index[tostring(reaper.GetTrack(proj, i))] = i + 1 end
  local tracks, sends = {}, {}
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local par = reaper.GetParentTrack(tr)
    local fx = reaper.TrackFX_GetInstrument(tr) -- -1 when the instrument is offline (measured)
    local fxon = b(iv(tr, "I_FXEN"))
    local audio, midi = item_kinds(tr)
    tracks[i + 1] = {
      guid = reaper.GetTrackGUID(tr), name = name,
      fdepth = iv(tr, "I_FOLDERDEPTH"), parent = par and index[tostring(par)] or 0,
      main = b(iv(tr, "B_MAINSEND")), poffs = iv(tr, "C_MAINSEND_OFFS"), pnch = iv(tr, "C_MAINSEND_NCH"),
      nchan = iv(tr, "I_NCHAN"), mute = b(iv(tr, "B_MUTE")), phase = b(iv(tr, "B_PHASE")),
      fxon = fxon, nfx = reaper.TrackFX_GetCount(tr),
      instr = fx >= 0 and fxon and reaper.TrackFX_GetEnabled(tr, fx),
      audio = audio, midi = midi, hwout = reaper.GetTrackNumSends(tr, 1),
      arm = b(iv(tr, "I_RECARM")), recin = iv(tr, "I_RECINPUT"), recmon = iv(tr, "I_RECMON"),
    }
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local function sv(key) return reaper.GetTrackSendInfo_Value(tr, 0, k, key) end
      local dst = reaper.GetTrackSendInfo_Value(tr, 0, k, "P_DESTTRACK")
      sends[#sends + 1] = {
        src = i + 1, dst = index[tostring(dst)] or 0,
        mode = math.floor(sv("I_SENDMODE")), vol = sv("D_VOL"), pan = sv("D_PAN"),
        mute = b(sv("B_MUTE")), mono = b(sv("B_MONO")), phase = b(sv("B_PHASE")),
        srcchan = math.floor(sv("I_SRCCHAN")), dstchan = math.floor(sv("I_DSTCHAN")), midi = math.floor(sv("I_MIDIFLAGS")),
      }
    end
  end
  local m = reaper.GetMasterTrack(proj)
  local snap = { v = SN.V, source = "api", tracks = tracks, sends = sends,
                 master = { guid = reaper.GetTrackGUID(m), nchan = iv(m, "I_NCHAN") } }
  SN.sort(snap)
  return snap
end

local SEND_KEYS = { "src", "dst", "srcchan", "dstchan", "mode", "mute", "mono", "phase", "midi", "vol", "pan" }
local function key_less(a, b)
  for _, k in ipairs(SEND_KEYS) do
    local x, y = a[k], b[k]
    if type(x) == "boolean" then x, y = x and 1 or 0, y and 1 or 0 end
    if x ~= y then return x < y end
  end
  return false
end

-- Sends in one canonical order (the API lists them by sender, the .rpp by receiver).
function SN.sort(snap)
  table.sort(snap.sends, key_less)
  return snap
end

SN.TRACK_KEYS = { "guid", "name", "fdepth", "parent", "main", "poffs", "pnch", "nchan", "mute", "phase", "fxon", "nfx",
                  "instr", "audio", "midi", "hwout", "arm", "recin", "recmon" }

local function same(x, y)
  if type(x) == "number" and type(y) == "number" then
    return math.abs(x - y) <= 1e-9 * math.max(1, math.abs(x), math.abs(y))
  end
  return x == y
end

-- True when two snapshots hold the same structure. Exact comparison, so it is meant for two
-- API snapshots (the engine asks it every time it looks, ~0.1 ms at 224 tracks).
function SN.equal(a, b)
  local ta, tb = a.tracks, b.tracks
  if #ta ~= #tb or #a.sends ~= #b.sends or a.master.nchan ~= b.master.nchan then return false end
  for k = 1, #ta do
    local x, y = ta[k], tb[k]
    if x.guid ~= y.guid or x.parent ~= y.parent or x.fdepth ~= y.fdepth or x.main ~= y.main or x.poffs ~= y.poffs
       or x.pnch ~= y.pnch or x.nchan ~= y.nchan or x.mute ~= y.mute or x.phase ~= y.phase or x.fxon ~= y.fxon
       or x.nfx ~= y.nfx or x.instr ~= y.instr or x.audio ~= y.audio or x.midi ~= y.midi or x.hwout ~= y.hwout
       or x.arm ~= y.arm or x.recin ~= y.recin or x.recmon ~= y.recmon or x.name ~= y.name then
      return false
    end
  end
  local sa, sb = a.sends, b.sends
  for k = 1, #sa do
    local x, y = sa[k], sb[k]
    if x.src ~= y.src or x.dst ~= y.dst or x.srcchan ~= y.srcchan or x.dstchan ~= y.dstchan or x.mode ~= y.mode
       or x.mute ~= y.mute or x.mono ~= y.mono or x.phase ~= y.phase or x.midi ~= y.midi or x.vol ~= y.vol then -- pan plays no part in roles
      return false
    end
  end
  return true
end

-- Differences between two snapshots, as readable lines (empty when they agree).
function SN.diff(a, b, limit)
  limit = limit or 40
  local out = {}
  local function add(s) if #out < limit then out[#out + 1] = s end end
  if #a.tracks ~= #b.tracks then add(("track count %d vs %d"):format(#a.tracks, #b.tracks)) end
  for k = 1, math.min(#a.tracks, #b.tracks) do
    local x, y = a.tracks[k], b.tracks[k]
    for _, key in ipairs(SN.TRACK_KEYS) do
      if not same(x[key], y[key]) then
        add(("track %d '%s' %s: %s vs %s"):format(k, x.name, key, tostring(x[key]), tostring(y[key])))
      end
    end
  end
  for _, key in ipairs({ "guid", "nchan" }) do
    if not same(a.master[key], b.master[key]) then add(("master %s: %s vs %s"):format(key, tostring(a.master[key]), tostring(b.master[key]))) end
  end
  if #a.sends ~= #b.sends then add(("send count %d vs %d"):format(#a.sends, #b.sends)) end
  for k = 1, math.min(#a.sends, #b.sends) do
    local x, y = a.sends[k], b.sends[k]
    for _, key in ipairs(SEND_KEYS) do
      if not same(x[key], y[key]) then
        add(("send %d (%d->%d) %s: %s vs %s"):format(k, x.src, x.dst, key, tostring(x[key]), tostring(y[key])))
      end
    end
  end
  return out
end

return SN
