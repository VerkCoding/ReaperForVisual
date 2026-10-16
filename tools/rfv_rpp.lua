-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The routing snapshot of engine/rfv_snapshot.lua, read from a project's .rpp text instead of
-- the API. Nothing is opened in REAPER, so no plugin loads and no licence dialog can appear:
-- this is how tests read the owner's real projects. Plain Lua; reaper.* is not used.
--
--   local R = dofile(".../tools/rfv_rpp.lua")
--   local snap = R.snapshot_file(path)       -- or nil, message
--
-- Encodings, each checked against the API by tests/snapshot_test.lua:
--   <TRACK {GUID}             a track, in track order; TRACKID repeats the GUID
--   ISBUS a b                 a = 1 opens a folder; a = 2 closes -b levels (I_FOLDERDEPTH = b)
--   MAINSEND on offs          master/parent send and its channel offset
--   MAINSEND_NCH n            its channel count, when not "all"
--   AUXRECV src mode vol pan mute mono phase srcchan dstchan panlaw midiflags automode name
--                             a receive, listed on the receiving track; src is 0-based
--   HWOUT ...                 one hardware output each
--   REC arm input monitor ... record arm, input, monitoring
--   MUTESOLO mute solo ...,  IPHASE p,  NCHAN n,  FX on
--   <FXCHAIN: BYPASS bypass offline ... before each FX; an instrument's name starts with
--             "VSTi:", "VST3i:", "CLAPi:", "AUi:", "LV2i:" or "DXi:"
--   <ITEM: MUTE m ..., takes separated by TAKE lines (SEL marks the active one, NULL an empty
--          take), each take's <SOURCE kind (SECTION wraps the real one)

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local SN = dofile(HERE .. ".." .. package.config:sub(1, 1) .. "engine" .. package.config:sub(1, 1) .. "rfv_snapshot.lua")

local R = {}

-- Split a line into tokens; REAPER quotes with ", ' or ` (whichever the text does not hold).
function R.tokens(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    local s = line:find("%S", i)
    if not s then break end
    local c = line:sub(s, s)
    if c == '"' or c == "'" or c == "`" then
      local e = line:find(c, s + 1, true)
      if not e then e = n + 1 end
      out[#out + 1] = line:sub(s + 1, e - 1)
      i = e + 1
    else
      local e = line:find("%s", s) or (n + 1)
      out[#out + 1] = line:sub(s, e - 1)
      i = e
    end
  end
  return out
end

local INSTR_PREFIX = { "VSTi:", "VST3i:", "CLAPi:", "AUi:", "LV2i:", "DXi:" }
local FX_TAGS = { VST = true, JS = true, CLAP = true, AU = true, DX = true, LV2 = true, VIDEO_EFFECT = true, CONTAINER = true }
local MIDI_KINDS = { MIDI = true, MIDIPOOL = true }

local function is_instrument(head)
  local name = R.tokens(head)[2] or ""
  for _, p in ipairs(INSTR_PREFIX) do
    if name:sub(1, #p) == p then return true end
  end
  return false
end

local function int(x) return math.floor((tonumber(x) or 0) + 0.5) end

-- Snapshot from an iterator of lines.
function R.snapshot_lines(lines)
  local tracks, sends, master = {}, {}, { guid = "", nchan = 2 }
  local stack, top = {}, nil
  local cur, item, take, fxst = nil, nil, nil, nil
  local folders = {}

  local function new_track(guid)
    cur = { guid = guid or "", name = "", fdepth = 0, parent = 0, main = true, poffs = 0, pnch = 0, nchan = 2,
            mute = false, phase = false, fxon = true, nfx = 0, instr = false, audio = false, midi = false, hwout = 0,
            arm = false, recin = 0, recmon = 0 }
    tracks[#tracks + 1] = cur
    cur.k = #tracks
  end

  local function end_track()
    -- folder parent from the running depth
    cur.parent = folders[#folders] or 0
    if cur.fdepth == 1 then folders[#folders + 1] = cur.k
    elseif cur.fdepth < 0 then for _ = 1, -cur.fdepth do folders[#folders] = nil end end
    if fxst and fxst.first_instr then
      cur.instr = cur.fxon and not fxst.first_instr.bypass
    end
    cur.midi = cur.midi and not cur.audio -- as the API snapshot: MIDI counts only without audio
    cur.k, cur, fxst = nil, nil, nil
  end

  local function end_item()
    if not item.mute then
      local act
      for _, t in ipairs(item.takes) do if t.sel then act = t break end end
      act = act or item.takes[1]
      if act and act.kind and act.kind ~= "EMPTY" then
        if MIDI_KINDS[act.kind] then cur.midi = true else cur.audio = true end
      end
    end
    item, take = nil, nil
  end

  for raw in lines do
    local s = raw:find("%S")
    if s then
      local c = raw:sub(s, s)
      if c == "<" then
        local line = raw:sub(s + 1)
        local tag = line:match("^(%S+)") or ""
        if top == "REAPER_PROJECT" and tag == "TRACK" then
          new_track(line:match("^TRACK%s+(%b{})"))
        elseif top == "TRACK" and cur then
          if tag == "FXCHAIN" then fxst = { pending = nil, first_instr = nil }
          elseif tag == "ITEM" then item = { mute = false, takes = { {} } }; take = item.takes[1] end
        elseif top == "FXCHAIN" and fxst and FX_TAGS[tag] then
          cur.nfx = cur.nfx + 1
          local byp = fxst.pending or { false, false }
          fxst.pending = nil
          -- An offline instrument is not one (TrackFX_GetInstrument skips it, measured).
          if not fxst.first_instr and is_instrument(line) and not byp[2] then
            fxst.first_instr = { bypass = byp[1] }
          end
        elseif item and tag == "SOURCE" and (top == "ITEM" or take.kind == "SECTION") then
          -- the take's source; a SECTION (reversed or looped section) holds the real one inside
          take.kind = line:match("^SOURCE%s+(%S+)") or ""
        end
        stack[#stack + 1] = tag
        top = tag
      elseif c == ">" then
        local tag = stack[#stack]
        stack[#stack] = nil
        top = stack[#stack]
        if tag == "TRACK" and cur then end_track()
        elseif tag == "ITEM" and item then end_item() end
      elseif top == "TRACK" and cur then
        local key = raw:match("^%s*(%S+)")
        if key == "NAME" then cur.name = R.tokens(raw)[2] or ""
        elseif key == "ISBUS" then
          local t = R.tokens(raw)
          local a, d = int(t[2]), int(t[3])
          cur.fdepth = (a == 1 and 1) or (a == 2 and d) or 0
        elseif key == "MAINSEND" then
          local t = R.tokens(raw)
          cur.main, cur.poffs = int(t[2]) ~= 0, int(t[3])
        elseif key == "MAINSEND_NCH" then cur.pnch = int(R.tokens(raw)[2])
        elseif key == "NCHAN" then cur.nchan = int(R.tokens(raw)[2])
        elseif key == "MUTESOLO" then cur.mute = int(R.tokens(raw)[2]) ~= 0
        elseif key == "IPHASE" then cur.phase = int(R.tokens(raw)[2]) ~= 0
        elseif key == "FX" then cur.fxon = int(R.tokens(raw)[2]) ~= 0
        elseif key == "HWOUT" then cur.hwout = cur.hwout + 1
        elseif key == "REC" then
          local t = R.tokens(raw)
          cur.arm, cur.recin, cur.recmon = int(t[2]) ~= 0, int(t[3]), int(t[4])
        elseif key == "AUXRECV" then
          local t = R.tokens(raw)
          sends[#sends + 1] = {
            src = int(t[2]) + 1, dst = cur.k, mode = int(t[3]), vol = tonumber(t[4]) or 0, pan = tonumber(t[5]) or 0,
            mute = int(t[6]) ~= 0, mono = int(t[7]) ~= 0, phase = int(t[8]) ~= 0,
            srcchan = int(t[9]), dstchan = int(t[10]), midi = int(t[12]),
          }
        elseif key == "TRACKID" and cur.guid == "" then cur.guid = R.tokens(raw)[2] or ""
        end
      elseif top == "FXCHAIN" and fxst then
        if raw:match("^%s*BYPASS%s") then
          local t = R.tokens(raw)
          fxst.pending = { int(t[2]) ~= 0, int(t[3]) ~= 0 }
        end
      elseif top == "ITEM" and item then
        local key = raw:match("^%s*(%S+)")
        if key == "MUTE" then item.mute = int(R.tokens(raw)[2]) ~= 0
        elseif key == "TAKE" then
          take = {}
          item.takes[#item.takes + 1] = take
          for _, w in ipairs(R.tokens(raw)) do
            if w == "SEL" then take.sel = true elseif w == "NULL" then take.kind = "EMPTY" end
          end
        end
      elseif top == "REAPER_PROJECT" then
        local key = raw:match("^%s*(%S+)")
        if key == "MASTER_NCH" then master.nchan = int(R.tokens(raw)[2])
        elseif key == "MASTER_TRACKID" then master.guid = R.tokens(raw)[2] or "" end
      end
    end
  end
  return SN.sort({ v = SN.V, source = "rpp", tracks = tracks, sends = sends, master = master })
end

function R.snapshot_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local ok, snap = pcall(R.snapshot_lines, f:lines())
  f:close()
  if not ok then return nil, snap end
  return snap
end

return R
