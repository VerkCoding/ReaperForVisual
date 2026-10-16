-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The view actions (roadmap step 6): what the five "ReaperForVisual - ..." scripts share. Each
-- reads the tracks selected in REAPER (the master excluded), changes the choices through the
-- store (rfv_store.lua: read, change, write at once) and tells a running engine through ExtState
-- "ping", with a line saying what happened, so the page shows it at once. They work with the
-- engine stopped too: the choices are kept and the engine picks them up when it starts.
--
-- Nothing here touches the project: reading the selection changes neither dirty nor undo, and
-- each script ends with reaper.defer(function() end), because a plain script run as an action
-- sweeps a pending change of the user's into a "ReaScript: Run" undo point (measured, step 3).
-- With nothing selected, Show, Add, Remove and Group change nothing (a slip of the mouse must
-- not empty the view) and say so.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local S = dofile(HERE .. "rfv_store.lua")
local V = dofile(HERE .. "rfv_view.lua")

local A = {}
A.SECTION = "ReaperForVisual" -- the engine's ExtState section (tests set _G.RFV_SECTION)

-- GUIDs and names of the tracks selected in proj, in track order, without the master.
function A.selected(proj)
  local guids, names = {}, {}
  for i = 0, reaper.CountSelectedTracks2(proj, false) - 1 do
    local tr = reaper.GetSelectedTrack2(proj, i, false)
    guids[#guids + 1] = reaper.GetTrackGUID(tr)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    names[#names + 1] = nm
  end
  return guids, names
end

local function plural(n, what) return ("%d %s%s"):format(n, what, n == 1 and "" or "s") end

-- op: "show", "add", "remove", "group" or "all" (toggle all / chosen). Returns ok, message.
-- own_light: run as the "Show all or chosen tracks" action itself, which lights its own button
-- (from the View menu the engine keeps that light in step instead).
function A.run(op, own_light)
  local proj = reaper.EnumProjects(-1)
  local guids, names = A.selected(proj)
  local msg, ok, doc_mode = nil, false, nil
  if op ~= "all" and #guids == 0 then
    msg = "no track selected: the view is unchanged"
  else
    local st = {}
    S.follow(proj, st) -- also moves an unsaved project's choices into its file after a first save
    local said
    local done, err = S.edit(proj, st, function(doc)
      if op == "show" then V.show(doc, guids); said = "shows " .. plural(#guids, "track")
      elseif op == "add" then V.add(doc, guids); said = "added " .. plural(#guids, "track")
      elseif op == "remove" then V.remove(doc, guids); said = "removed " .. plural(#guids, "track")
      elseif op == "group" then said = ("grouped %s as \"%s\""):format(plural(#guids, "track"), V.group(doc, guids, names) or "?")
      elseif op == "all" then V.mode(doc, "toggle"); said = doc.view.mode == "all" and "shows the whole mix" or "shows the chosen tracks"
      end
      doc_mode = doc.view.mode
    end)
    ok = done
    msg = done and ("view " .. said) or ("the view could not be changed: " .. tostring(err and (err.msg or err.code)))
  end
  local section = _G.RFV_SECTION or A.SECTION
  if op == "all" and ok and own_light then
    -- its toolbar button lights while the whole mix is shown; a running engine keeps the light
    -- in step with the active tab, and learns here which command is this one
    local all = doc_mode == "all"
    if reaper.set_action_options then reaper.set_action_options(1 | 2 | (all and 4 or 8)) end
    local _, _, sec, cmd = reaper.get_action_context()
    if sec == 0 and cmd and cmd > 0 then reaper.SetExtState(section, "all_cmd", tostring(cmd), false) end
  end
  local n = (tonumber((reaper.GetExtState(section, "ping"):match("^(%d+)"))) or 0) + 1
  reaper.SetExtState(section, "ping", ("%d|%s"):format(n, msg), false)
  return ok, msg
end

-- A command for the running engine, the way the page sends one (ExtState "cmd" =
-- "<seq>|<bytes>|<json>"): Undo and Redo live in the engine's memory. The sequence number is one
-- past the engine's last answer, so the engine takes it and the page's next one (its clock in
-- ms) stays above it. Returns false when no engine of this section is running.
function A.command(obj, proj)
  local section = _G.RFV_SECTION or A.SECTION
  local frame = reaper.GetExtState(section, "frame")
  local t = tonumber(frame:match('"t":([%d%.]+)'))
  if not frame:find('"state":"running"', 1, true) or not t or reaper.time_precise() - t > 2 then return false end
  local ack = tonumber(frame:match('"ack":(%d+)')) or 0
  obj.tab = tostring(proj or reaper.EnumProjects(-1))
  local body = S.json.encode(S.json.object(obj))
  reaper.SetExtState(section, "cmd", ("%d|%d|%s"):format(ack + 1, #body, body), false)
  return true
end

return A
