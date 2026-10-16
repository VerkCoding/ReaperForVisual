-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Helpers that build test projects in a temporary tab. Only REAPER's own FX are used, so a
-- fixture never raises a third-party licence dialog (a modal dialog freezes every script).

local L = {}
L.SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")

-- Where material that is not in the repository lives on this computer: an environment variable
-- of REAPER's, else tests/local_paths.lua (not committed; see tests/local_paths.example.lua),
-- else nil, and the tests that need it say so.
local function local_paths()
  local chunk, err = loadfile(HERE .. ".." .. L.SEP .. "local_paths.lua")
  if not chunk then
    if err and not err:find("cannot open", 1, true) then error(err, 0) end -- a mistake in the file
    return {}
  end
  local t = chunk()
  return type(t) == "table" and t or {}
end

function L.env()
  local temp = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
  local lp = local_paths()
  return {
    media = os.getenv("RFV_MEDIA") or lp.media,          -- the multitrack of the band fixture
    -- a second multitrack (step 10b): Actions, "South Of The Water" (Cambridge-MT, for education
    -- only: never copied into the repository)
    media2 = os.getenv("RFV_MEDIA2") or lp.media2,
    projects = os.getenv("RFV_PROJECTS") or lp.projects, -- real projects, read as text only
    second = os.getenv("RFV_SECOND") or lp.second,       -- axes_second's files, separated by ";"
    signals = os.getenv("RFV_SIGNALS") or (temp .. L.SEP .. "rfv-signals"),  -- tools/make_signals.py
    truth = os.getenv("RFV_TRUTH") or (temp .. L.SEP .. "rfv-truth"),
  }
end

-- The message of a test or fixture that needs a path it was not given.
function L.no_path(what, key, var)
  return ("no %s on this computer: set %s, or %s in tests/local_paths.lua"):format(what, var, key)
end

-- New track at the end. fd: folder depth change (1 opens a folder, -1 closes one level).
-- o: pan, width, mode (5 = stereo pan), vol (linear), mainsend (false to turn it off)
function L.track(P, name, fd, o)
  o = o or {}
  local n = reaper.CountTracks(P)
  reaper.InsertTrackAtIndex(n, false)
  local tr = reaper.GetTrack(P, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", fd or 0)
  if o.mode then reaper.SetMediaTrackInfo_Value(tr, "I_PANMODE", o.mode) end
  if o.pan then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", o.pan) end
  if o.width then reaper.SetMediaTrackInfo_Value(tr, "D_WIDTH", o.width) end
  if o.vol then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", o.vol) end
  if o.mainsend == false then reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0) end
  return tr
end

-- Item from a file. offs: where in the source to start (seconds).
function L.item(tr, file, pos, len, offs)
  local src = reaper.PCM_Source_CreateFromFile(file)
  local slen = reaper.GetMediaSourceLength(src)
  if slen <= 0 then error("source not readable: " .. file) end
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos or 0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len or slen)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", offs or 0)
  return it, tk
end

-- Send from src to dst. o: pan, mode (0 post-fader, 1 pre-FX, 3 post-FX)
function L.send(src, dst, vol, o)
  o = o or {}
  local k = reaper.CreateTrackSend(src, dst)
  reaper.SetTrackSendInfo_Value(src, 0, k, "D_VOL", vol or 1)
  if o.pan then reaper.SetTrackSendInfo_Value(src, 0, k, "D_PAN", o.pan) end
  if o.mode then reaper.SetTrackSendInfo_Value(src, 0, k, "I_SENDMODE", o.mode) end
  return k
end

function L.fx(tr, name)
  local i = reaper.TrackFX_AddByName(tr, name, false, -1)
  if i < 0 then error("FX not found: " .. name) end
  if name == "ReaEQ" then
    -- REAPER's default ReaEQ may carry a fifth band (high pass 100 Hz); keep only what we set.
    reaper.TrackFX_SetNamedConfigParm(tr, i, "BANDENABLED4", "0")
  end
  return i
end

local function display_number(tr, fx, p)
  local _, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  if s:find("inf") then return s:find("^%-") and -1e9 or 1e9 end
  local n, k = s:match("([-+]?%d+%.?%d*)%s*([kK]?)")
  n = tonumber(n)
  if not n then return nil, s end
  return k ~= "" and n * 1000 or n
end

-- Set a parameter by the number its display shows (dB, Hz, ratio...), by bisection on the
-- normalized value; the display must move one way across the range. Returns the display.
function L.set(tr, fx, pname, target)
  local p
  for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, n = reaper.TrackFX_GetParamName(tr, fx, i, "")
    if n == pname then p = i break end
  end
  if not p then error("parameter not found: " .. pname) end
  local function at(v) reaper.TrackFX_SetParamNormalized(tr, fx, p, v) return display_number(tr, fx, p) end
  local lo, hi = 0.0, 1.0
  local up = at(1) > at(0)
  if target <= -1e5 then at(up and 0 or 1) else
    -- The display is rounded, so many normalized values show the target. Find where that
    -- run starts and ends and take its middle: the closest the display lets us get.
    local function first(pred)
      local lo, hi = 0.0, 1.0
      for _ = 1, 40 do local mid = (lo + hi) / 2; if pred(at(mid)) then hi = mid else lo = mid end end
      return hi
    end
    local a, b
    if up then a = first(function(d) return d >= target end); b = first(function(d) return d > target end)
    else a = first(function(d) return d <= target end); b = first(function(d) return d < target end) end
    local v = (a + b) / 2
    if math.abs(at(v) - target) > math.abs(at(a) - target) then v = a end
    at(v)
  end
  local _, s = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  return s
end

-- Run an action only if its ID still names the action we mean.
function L.act(id, expect)
  local name = reaper.kbd_getTextFromCmd(id, nil) or ""
  if not name:find(expect, 1, true) then error(("action %d is '%s', expected '%s'"):format(id, name, expect)) end
  reaper.Main_OnCommand(id, 0)
end

-- Pan automation: a straight line from `from` to `to` between t0 and t1, in envelope values.
-- REAPER stores pan envelopes inverted: envelope -1 is pan +1 (right), measured by render.
function L.pan_sweep(tr, t0, t1, from, to)
  local env = reaper.GetTrackEnvelopeByName(tr, "Pan")
  if not env then
    reaper.SetOnlyTrackSelected(tr)
    L.act(40407, "Toggle track pan envelope visible")
    env = reaper.GetTrackEnvelopeByName(tr, "Pan")
  end
  if not env then error("no pan envelope") end
  reaper.InsertEnvelopePoint(env, t0, from, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, t1, to, 0, 0, false, true)
  reaper.Envelope_SortPoints(env)
  return env
end

-- A track's own pan law, in dB at the centre (-3 or -6); nil restores the project default.
function L.panlaw(tr, db)
  reaper.SetMediaTrackInfo_Value(tr, "D_PANLAW", db and 10 ^ (db / 20) or -1)
end

-- Dual pan mode: each input channel panned on its own.
function L.dualpan(tr, l, r)
  reaper.SetMediaTrackInfo_Value(tr, "I_PANMODE", 6)
  reaper.SetMediaTrackInfo_Value(tr, "D_DUALPANL", l)
  reaper.SetMediaTrackInfo_Value(tr, "D_DUALPANR", r)
end

-- A MIDI item holding one chord for `len` seconds (for a virtual instrument).
function L.midi_chord(tr, pos, len, pitches)
  local it = reaper.CreateNewMIDIItemInProj(tr, pos, pos + len, false)
  local tk = reaper.GetActiveTake(it)
  local e = reaper.MIDI_GetPPQPosFromProjTime(tk, pos + len - 0.01)
  for _, p in ipairs(pitches) do reaper.MIDI_InsertNote(tk, false, false, 0, e, 0, p, 100, true) end
  reaper.MIDI_Sort(tk)
  return it
end

function L.region(P, name, s, e)
  return reaper.AddProjectMarker2(P, true, s, e, name, -1, 0)
end

-- Save the tab under path and reopen it there, clean. Returns the (possibly new) pointer.
function L.save_reopen(P, path)
  reaper.RecursiveCreateDirectory(path:match("^(.*)[/\\]"), 0)
  reaper.Main_SaveProjectEx(P, path, 0)
  reaper.Main_openProject("noprompt:" .. path)
  return reaper.EnumProjects(-1)
end

return L
