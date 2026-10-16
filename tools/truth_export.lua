-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Ground truth, REAPER side: write the project's structure as JSON and render every track as
-- a 32-bit float stereo file, in up to two layers:
--   own    each track's output (after its FX, fader and pan; a folder's holds its children)
--   heard  each track rendered through its parent buses and the master, as the listener hears
--          it ("selected tracks via master"), with every send muted for that render: the main
--          path only (a return is drawn on its own). Since 2026-10-11 (step 5); before, sends
--          passed, so the layer was only made on fixtures without sends.
-- tools/truth_stats.py turns the result into truth.json.
-- Development only. Run inside a temporary tab: rendering changes that project's settings.

local SEP = package.config:sub(1, 1)
local ROOT = debug.getinfo(1, "S").source:match("^@(.*[/\\])") .. ".." .. SEP
local J = dofile(ROOT .. "engine" .. SEP .. "rfv_json.lua")

local T = {}

local function guid(tr) return tr and reaper.GetTrackGUID(tr) or J.null end

function T.structure(P)
  local tracks = J.array{}
  for i = 0, reaper.CountTracks(P) - 1 do
    local tr = reaper.GetTrack(P, i)
    local _, name = reaper.GetTrackName(tr)
    local audio, midi = 0, 0
    for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, k))
      if tk then if reaper.TakeIsMIDI(tk) then midi = midi + 1 else audio = audio + 1 end end
    end
    local sends = J.array{}
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      sends[#sends + 1] = {
        dest = guid(reaper.GetTrackSendInfo_Value(tr, 0, k, "P_DESTTRACK")),
        vol = reaper.GetTrackSendInfo_Value(tr, 0, k, "D_VOL"), pan = reaper.GetTrackSendInfo_Value(tr, 0, k, "D_PAN"),
        mode = reaper.GetTrackSendInfo_Value(tr, 0, k, "I_SENDMODE"), mute = reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE"),
        src = reaper.GetTrackSendInfo_Value(tr, 0, k, "I_SRCCHAN"), dst = reaper.GetTrackSendInfo_Value(tr, 0, k, "I_DSTCHAN"),
      }
    end
    tracks[#tracks + 1] = {
      index = i, guid = guid(tr), name = name, parent = guid(reaper.GetParentTrack(tr)),
      folderdepth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"), mainsend = reaper.GetMediaTrackInfo_Value(tr, "B_MAINSEND"),
      pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN"), width = reaper.GetMediaTrackInfo_Value(tr, "D_WIDTH"),
      panmode = reaper.GetMediaTrackInfo_Value(tr, "I_PANMODE"), vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL"),
      panlaw = reaper.GetMediaTrackInfo_Value(tr, "D_PANLAW"),
      dualpan = { reaper.GetMediaTrackInfo_Value(tr, "D_DUALPANL"), reaper.GetMediaTrackInfo_Value(tr, "D_DUALPANR") },
      mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"), nchan = reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN"),
      audio_items = audio, midi_items = midi, instrument = reaper.TrackFX_GetInstrument(tr) >= 0,
      fx = reaper.TrackFX_GetCount(tr), sends = sends,
    }
  end
  local regions = J.array{}
  local _, nm, nr = reaper.CountProjectMarkers(P)
  for k = 0, nm + nr - 1 do
    local _, isr, s, e, name = reaper.EnumProjectMarkers2(P, k)
    if isr then regions[#regions + 1] = { name = name, start = s, ["end"] = e } end
  end
  local _, fn = reaper.EnumProjects(-1)
  local m = reaper.GetMasterTrack(P)
  local master = { pan = reaper.GetMediaTrackInfo_Value(m, "D_PAN"), width = reaper.GetMediaTrackInfo_Value(m, "D_WIDTH"),
                   vol = reaper.GetMediaTrackInfo_Value(m, "D_VOL"), panmode = reaper.GetMediaTrackInfo_Value(m, "I_PANMODE"),
                   fx = reaper.TrackFX_GetCount(m), mute = reaper.GetMediaTrackInfo_Value(m, "B_MUTE") }
  return { project = fn, length = reaper.GetProjectLength(P), tracks = tracks, regions = regions, master = master }
end

-- Render all tracks into dir/stems ("own") or dir/heard ("heard"); returns the target paths
-- in track order and the seconds the render took.
function T.render(P, dir, srate, kind)
  local heard = kind == "heard"
  local stems = dir .. SEP .. (heard and "heard" or "stems")
  reaper.RecursiveCreateDirectory(stems, 0)
  reaper.Main_OnCommand(40101, 0) -- media online: with offlineinact a background render is silent
  for i = 0, reaper.CountMediaItems(P) - 1 do
    local tk = reaper.GetActiveTake(reaper.GetMediaItem(P, i))
    if tk and not reaper.TakeIsMIDI(tk) and reaper.GetMediaSourceLength(reaper.GetMediaItemTake_Source(tk)) <= 0 then
      error("media offline before render")
    end
  end
  for i = 0, reaper.CountTracks(P) - 1 do reaper.SetTrackSelected(reaper.GetTrack(P, i), true) end
  reaper.GetSetProjectInfo(P, "RENDER_SETTINGS", heard and 128 or 3, true) -- via master, or stems of selected tracks
  reaper.GetSetProjectInfo(P, "RENDER_BOUNDSFLAG", 1, true) -- entire project
  reaper.GetSetProjectInfo(P, "RENDER_TAILFLAG", 0, true)
  reaper.GetSetProjectInfo(P, "RENDER_CHANNELS", 2, true)
  reaper.GetSetProjectInfo(P, "RENDER_SRATE", srate or 48000, true)
  reaper.GetSetProjectInfo_String(P, "RENDER_FILE", stems, true)
  reaper.GetSetProjectInfo_String(P, "RENDER_PATTERN", "$tracknumber", true)
  reaper.GetSetProjectInfo_String(P, "RENDER_FORMAT", "ZXZhdyAAAQ==", true) -- WAV, 32-bit float
  local _, targets = reaper.GetSetProjectInfo_String(P, "RENDER_TARGETS", "", false)
  local list = {}
  for t in targets:gmatch("[^;]+") do list[#list + 1] = t end
  if #list ~= reaper.CountTracks(P) then error(("render targets %d for %d tracks"):format(#list, reaper.CountTracks(P))) end
  -- An existing target can raise an "overwrite?" dialog, and a modal dialog freezes scripts.
  for _, t in ipairs(list) do os.remove(t) end
  -- "Heard" means through the main path (roadmap step 5): a track rendered via the master
  -- would also carry what its sends feed into returns, so sends are muted for this render
  -- and put back afterwards. Returns are judged by their own output instead.
  local muted = {}
  if heard then
    for i = 0, reaper.CountTracks(P) - 1 do
      local tr = reaper.GetTrack(P, i)
      for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        muted[#muted + 1] = { tr, k, reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") }
        reaper.SetTrackSendInfo_Value(tr, 0, k, "B_MUTE", 1)
      end
    end
  end
  local t0 = reaper.time_precise()
  reaper.Main_OnCommand(42230, 0) -- render, closing the render window afterwards
  local took = reaper.time_precise() - t0
  for _, m in ipairs(muted) do reaper.SetTrackSendInfo_Value(m[1], 0, m[2], "B_MUTE", m[3]) end
  return list, took
end

-- Structure, own layer and (if heard) heard layer, plus structure.json. Returns a summary.
-- A master that is muted or carries FX would make the heard layer lie, so it is refused.
function T.export(P, dir, srate, heard)
  local st = T.structure(P)
  local list, secs = T.render(P, dir, srate, "own")
  for i, t in ipairs(st.tracks) do t.stem = list[i] end
  local hsecs
  if heard then
    if st.master.mute ~= 0 or st.master.fx > 0 then error("heard layer needs an unmuted master without FX") end
    local hl
    hl, hsecs = T.render(P, dir, srate, "heard")
    for i, t in ipairs(st.tracks) do t.heard = hl[i] end
  end
  st.srate = srate or 48000
  local f = assert(io.open(dir .. SEP .. "structure.json", "wb"))
  f:write(J.encode(st, "  "), "\n")
  f:close()
  local missing = 0
  for _, t in ipairs(st.tracks) do
    for _, p in ipairs({ t.stem, t.heard }) do if p ~= nil and not reaper.file_exists(p) then missing = missing + 1 end end
  end
  return ("rendered %d own%s in %.1f s%s, missing %d, into %s"):format(#list, heard and " + heard" or "", secs,
    hsecs and string.format(" + %.1f s", hsecs) or "", missing, dir)
end

return T
