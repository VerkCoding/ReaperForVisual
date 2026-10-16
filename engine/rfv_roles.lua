-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Roles from routing, never from names: a pure function of a routing snapshot
-- (engine/rfv_snapshot.lua). The user decides which tracks to observe; roles only decide how
-- a chosen track is drawn and where it is heard (DESIGN.md, "Reading any project").
--
-- Result per track (index = track order):
--   role    "source" | "bus" | "passthrough" | "return" | "mixbus" | "ignored", or "layer"
--           (only when the user says so)
--   kind    what made it so: items, instrument, live, output (an instrument's extra outputs),
--           folder, sends, parallel, empty, midi_to_instrument, midi_no_instrument,
--           sidechain_only, organizing, instrument_no_midi, unheard, unexplained (the meter
--           safety net), user (an override)
--   reason  one line for people (names are used in the text only)
--   flags   ambiguous or notable cases: tie, parallel, own_sound, receives_sends, muted, live,
--           midi_no_instr, hw_only, side_parent, feedback, unexplained, user
--   dry     where its own signal goes on its main path (track index, 0 = master, nil = nowhere)
--   via     how it gets there: "master send", "folder" or "send"
--   path    the buses on the main path above it, nearest first (master excluded)
--   group   the object it belongs to at the default level, just under the mix bus (may be
--           itself; 0 for a mix bus, the master's level, or an ignored track)
--   level   buses between it and its group, pass-throughs not counted
--   members sources (or, in a template, feeding tracks) that reach it on a main or same-level
--           path (buses, returns, mix buses)
--   reach   true when its signal reaches the master
--   layer_of  for role "layer" (set by the user): the track it is a layer of
--
-- opts (all keyed by track GUID, any case; GUIDs of missing tracks are ignored):
--   roles  the user's overrides from .rfv.json: "source", "bus", "return", "ignore",
--          "layer:<GUID>"; applied after the routing is read (kind "user", flag "user")
--   paths  the user's choice of main path for a track whose sends tie: GUID -> GUID
--   heard  tracks the engine's meters heard although the routing shows no source; they
--          become sources of kind "unexplained" (the meter safety net)
--
-- Measured facts it relies on (REAPER 7.82): MIDI travels through a parent (folder) send;
-- I_MIDIFLAGS low 5 bits = 31 turns a send's MIDI off; an offline instrument is not reported
-- by TrackFX_GetInstrument; a JS synth or generator is never reported as an instrument.

local RO = {}
RO.TIE_DB = 0.005        -- sends this close count as the same level (REAPER shows 0.01 dB)
RO.MIXBUS_SHARE = 0.8    -- a bus holding this share of the sources is a mix bus
RO.MIXBUS_MIN = 3        -- ... when there are at least this many (else feeding tracks, see below)

local function db(v) return 20 * math.log(math.max(v, 1e-12), 10) end
local function midi_on(flags) return (flags & 31) ~= 31 end

local AUDIBLE = { main = true, audio = true, extra = true }
local E0 = {}
local USER_ROLE = { source = "source", bus = "bus", ["return"] = "return", ignore = "ignored" }

function RO.classify(snap, opts)
  opts = opts or E0
  local T, n = snap.tracks, #snap.tracks
  local byguid = {}
  for k = 1, n do byguid[T[k].guid:upper()] = k end
  local function idx(g) return g and byguid[tostring(g):upper()] end
  local heard, user_role, user_path = {}, {}, {}
  for g, v in pairs(opts.heard or E0) do local k = idx(g); if k and v then heard[k] = true end end
  for g, v in pairs(opts.roles or E0) do local k = idx(g); if k and type(v) == "string" then user_role[k] = v end end
  for g, v in pairs(opts.paths or E0) do local k, d = idx(g), idx(v); if k and d then user_path[k] = d end end
  local R = {}
  local function nm(k)
    if k == 0 then return "master" end
    local s = T[k].name
    return (s ~= "" and s or ("Track " .. k))
  end
  for k = 1, n do
    -- lists that most tracks never need (codry, par, dry_in, ...) are made on first use
    R[k] = { flags = {}, out = {}, path = {}, members = 0, group = 0, level = 0 }
  end
  local kids = {}
  for k = 1, n do kids[k] = 0 end
  for k = 1, n do local p = T[k].parent; if p > 0 then kids[p] = kids[p] + 1 end end
  local function flag(k, code)
    for _, c in ipairs(R[k].flags) do if c == code then return end end
    R[k].flags[#R[k].flags + 1] = code
  end
  local function push(r, key, v)
    local l = r[key]
    if not l then l = {}; r[key] = l end
    l[#l + 1] = v
  end

  -- Edges. The master/parent send carries MIDI too (measured).
  for k = 1, n do
    local t = T[k]
    if t.main then
      R[k].out[#R[k].out + 1] = { from = k, to = t.parent, kind = t.poffs >= 2 and "side" or "main", vol = 1, midi = true }
    end
  end
  for _, s in ipairs(snap.sends) do
    if s.src >= 1 and s.src <= n and s.dst >= 1 and s.dst <= n then
      local kind
      if s.mute then kind = "dead"
      elseif s.srcchan < 0 then kind = midi_on(s.midi) and "midi" or "dead"
      elseif (s.dstchan & 1023) >= 2 then kind = "side"
      elseif (s.srcchan & 1023) >= 2 then kind = "extra"
      else kind = "audio" end
      R[s.src].out[#R[s.src].out + 1] = { from = s.src, to = s.dst, kind = kind, vol = s.vol, midi = not s.mute and midi_on(s.midi) }
    end
  end

  -- Which tracks does MIDI reach? From MIDI items or a MIDI input that is armed and monitored,
  -- through any track (the FX chain passes MIDI on), along edges that carry MIDI.
  local midi_from, feeds_instr = {}, {}
  for k = 1, n do
    local t = T[k]
    if t.midi or (t.arm and t.recmon > 0 and t.recin >= 4096) then
      local seen, queue = { [k] = true }, { k }
      while #queue > 0 do
        local x = table.remove(queue)
        for _, e in ipairs(R[x].out) do
          if e.midi and e.to > 0 and not seen[e.to] then
            seen[e.to] = true
            queue[#queue + 1] = e.to
            midi_from[e.to] = midi_from[e.to] or k
            if T[e.to].instr then feeds_instr[k] = feeds_instr[k] or e.to end
          end
        end
      end
    end
  end

  -- Own sound.
  for k = 1, n do
    local t, r = T[k], R[k]
    if t.audio then r.own, r.own_why = "items", "audio items"
    elseif t.instr and t.midi then r.own, r.own_why = "instrument", "instrument with MIDI items"
    elseif t.instr and midi_from[k] then r.own, r.own_why = "instrument", "instrument playing MIDI from " .. nm(midi_from[k])
    elseif t.arm and t.recmon > 0 and t.recin >= 0 and t.recin < 4096 then r.own, r.own_why = "live", "live input: armed and monitoring"
    elseif t.arm and t.recmon > 0 and t.recin >= 4096 and t.instr then r.own, r.own_why = "live", "instrument played live: armed and monitoring"
    end
    if r.own == "live" then flag(k, "live") end
    if not r.own and t.midi and feeds_instr[k] then r.midi_feeder = feeds_instr[k] end
  end
  for k = 1, n do -- an instrument's extra outputs (channels 3 and up) make a sound of their own
    for _, e in ipairs(R[k].out) do
      if e.kind == "extra" and R[k].own and not R[e.to].own then
        R[e.to].own, R[e.to].own_why = "output", "outputs of " .. nm(k)
      end
    end
  end
  for k = 1, n do -- the meter safety net
    local r = R[k]
    if not r.own and heard[k] then
      r.own, r.midi_feeder = "unexplained", nil
      r.own_why = "its meter shows sound though its routing shows no source (a JS synth, a generator, or an input that is not armed)"
      flag(k, "unexplained")
    end
  end

  -- Which tracks reach the master: walk audible edges backwards from it.
  local into = {}
  for k = 1, n do
    for _, e in ipairs(R[k].out) do
      if AUDIBLE[e.kind] then
        into[e.to] = into[e.to] or {}
        table.insert(into[e.to], k)
      end
    end
  end
  local reach, queue = {}, { 0 }
  while #queue > 0 do
    local x = table.remove(queue)
    for _, k in ipairs(into[x] or {}) do
      if not reach[k] then reach[k] = true; queue[#queue + 1] = k end
    end
  end

  -- Main (dry) path. With the master/parent send on, it is the parent. With it off, the loudest
  -- audio send, preferring destinations that reach the master; on a tie the destination first
  -- in track order (deterministic), and the track is flagged. A parent send into a folder that
  -- never reaches the master (an organizing folder with its own send off, children left at
  -- REAPER's default) is no main path when a send does reach the master.
  for k = 1, n do
    local r = R[k]
    local main
    for _, e in ipairs(r.out) do if e.kind == "main" then main = e end end
    local dead = main and main.to > 0 and not reach[main.to]
    if main and not dead then
      r.dry, r.dry_how = main.to, main.to == 0 and "master send" or "folder"
    else
      local best, ties
      for pass = 1, dead and 1 or 2 do
        for _, e in ipairs(r.out) do
          if e.kind == "audio" and (pass == 2 or e.to == 0 or reach[e.to]) then
            if not best or db(e.vol) > db(best.vol) + RO.TIE_DB then best, ties = e, { e }
            elseif math.abs(db(e.vol) - db(best.vol)) <= RO.TIE_DB then
              ties[#ties + 1] = e
              if e.to < best.to then best = e end
            end
          end
        end
        if best then break end
      end
      for _, e in ipairs(user_path[k] and r.out or E0) do -- the user's choice wins
        if e.kind == "audio" and e.to == user_path[k] then
          best, ties = e, { e }
          for _, e2 in ipairs(r.out) do
            if e2 ~= e and e2.kind == "audio" and math.abs(db(e2.vol) - db(e.vol)) <= RO.TIE_DB then ties[#ties + 1] = e2 end
          end
          flag(k, "user")
          r.tie_why = "main path set by the user: " .. nm(e.to)
          break
        end
      end
      if best and dead then r.path_why = "its folder never reaches the master, so a send is its main path" end
      if not best and main then r.dry, r.dry_how = main.to, "folder" end -- a dead end, and nothing better
      if best then
        r.dry, r.dry_how = best.to, "send"
        if #ties > 1 and not r.tie_why then
          flag(k, "tie")
          local others = {}
          for _, e in ipairs(ties) do if e ~= best then others[#others + 1] = nm(e.to) end end
          r.tie_why = ("main path guessed by track order: %s, not %s (same send level)"):format(nm(best.to), table.concat(others, ", "))
        end
        for _, e in ipairs(ties) do if e ~= best then push(r, "codry", e.to) end end
        best.dry = true
        for _, e in ipairs(ties) do e.codry = e ~= best end
      end
    end
    for _, e in ipairs(r.out) do
      if e.kind == "audio" and not e.dry and not e.codry then push(r, "par", e.to) end
    end
  end

  -- Inputs of every track.
  for k = 1, n do
    local r = R[k]
    if r.dry and r.dry > 0 then
      push(R[r.dry], r.midi_feeder and "midi_kids" or "dry_in", k)
    end
    for _, d in ipairs(r.codry or E0) do push(R[d], "codry_in", k) end
    for _, d in ipairs(r.par or E0) do push(R[d], "par_in", k) end
    for _, e in ipairs(r.out) do
      if e.kind == "extra" then push(R[e.to], "extra_in", k)
      elseif e.kind == "side" and e.to > 0 then push(R[e.to], "side_in", k) end
    end
  end

  -- Roles.
  for k = 1, n do
    local t, r = T[k], R[k]
    local nd, nc, np = #(r.dry_in or E0), #(r.codry_in or E0), #(r.par_in or E0)
    if nd > 0 then
      r.role = "bus"
      local by_folder, by_send = 0, 0
      for _, x in ipairs(r.dry_in) do if R[x].dry_how == "folder" then by_folder = by_folder + 1 else by_send = by_send + 1 end end
      r.kind = by_folder >= by_send and "folder" or "sends"
      r.reason = ("bus: %d track%s on their main path (%s)"):format(nd, nd > 1 and "s" or "",
        by_send == 0 and "folder" or by_folder == 0 and "sends" or "folder and sends")
      if r.own then flag(k, "own_sound"); r.reason = r.reason .. "; also " .. r.own_why end
    elseif nc > 0 then
      r.role, r.kind = "return", "parallel"
      r.reason = ("parallel bus: fed by %d track%s at the same level as their main path"):format(nc, nc > 1 and "s" or "")
      flag(k, "parallel")
    elseif r.own then
      r.role, r.kind, r.reason = "source", r.own, "source: " .. r.own_why
      if np > 0 then flag(k, "receives_sends") end
    elseif np > 0 then
      r.role, r.kind = "return", "sends"
      r.reason = ("return: sends from %d track%s that reach%s the master another way (reverb, delay or parallel processing)"):format(np,
        np > 1 and "s" or "", np > 1 and "" or "es")
      flag(k, "parallel")
    else
      r.role = "ignored"
      if r.midi_feeder then r.kind, r.reason = "midi_to_instrument", "MIDI for " .. nm(r.midi_feeder)
      elseif t.midi then
        r.kind, r.reason = "midi_no_instrument", "MIDI items, no online instrument (offline, bypassed, a JS synth, or none)"
        flag(k, "midi_no_instr")
      elseif r.side_in then r.kind, r.reason = "sidechain_only", "receives sidechain signals only"
      elseif kids[k] > 0 then r.kind, r.reason = "organizing", "folder whose tracks send elsewhere"
      elseif t.instr then r.kind, r.reason = "instrument_no_midi", "instrument with no MIDI"
      else r.kind, r.reason = "empty", "no items and no audio input" end
    end
    if t.mute then flag(k, "muted") end
    if r.role ~= "ignored" and not reach[k] then
      local why = "never reaches the master"
      local side_main = t.main and t.poffs >= 2
      if side_main then flag(k, "side_parent"); why = why .. " (its parent send lands on channels 3 and up)" end
      if t.hwout > 0 then flag(k, "hw_only"); why = why .. " (hardware output only)" end
      r.was, r.role, r.kind, r.reason = r.role, "ignored", "unheard", why .. "; " .. r.reason
    end
    if r.tie_why then r.reason = r.reason .. "; " .. r.tie_why end
    if r.path_why then r.reason = r.reason .. "; " .. r.path_why end
  end

  -- Pass-throughs: a bus with exactly one input on a main path, itself a bus, no sound of its own.
  for k = 1, n do
    local r = R[k]
    if r.role == "bus" and #r.dry_in == 1 and not r.codry_in and not r.own then
      local x = R[r.dry_in[1]]
      if x.role == "bus" or x.role == "passthrough" or x.role == "return" then
        r.role = "passthrough"
        r.reason = "pass-through: carries only " .. nm(r.dry_in[1])
      end
    end
  end

  -- The user's role overrides come last; the routing's own answer stays in the reason.
  for k = 1, n do
    local want, r = user_role[k], R[k]
    if want then
      local role, of = USER_ROLE[want], nil
      if want:sub(1, 6) == "layer:" then of = idx(want:sub(7)); role = of and of ~= k and "layer" or nil end
      if role then
        r.reason = ("set by the user%s (the routing says %s: %s)"):format(of and (" as a layer of " .. nm(of)) or "", r.role, r.reason)
        r.was, r.role, r.kind, r.layer_of, r.user = r.role, role, "user", of, true
        flag(k, "user")
      end
    end
  end

  -- The mix-bus share is counted on the sources when there are at least MIXBUS_MIN of them, so
  -- spare empty tracks outside the mix bus do not dilute it. A template, with no sources yet,
  -- counts the tracks that could become one (empty tracks, MIDI tracks whose synth cannot be
  -- seen) instead.
  local feeders, basis = {}, "sources"
  for k = 1, n do if R[k].role == "source" then feeders[#feeders + 1] = k end end
  if #feeders < RO.MIXBUS_MIN then
    basis = "feeding tracks"
    for k = 1, n do
      local r = R[k]
      if r.role == "ignored" and reach[k] and (r.kind == "empty" or r.kind == "midi_no_instrument" or r.kind == "instrument_no_midi") then
        feeders[#feeders + 1] = k
      end
    end
  end
  -- One mark table for every walk: mark[y] == f means feeder f already counted at y.
  local mark, queue = {}, {}
  for _, f in ipairs(feeders) do
    mark[f] = f
    local qn = 1
    queue[1] = f
    while qn > 0 do
      local rx = R[queue[qn]]
      queue[qn] = nil
      qn = qn - 1
      local y = rx.dry
      if y and y > 0 and mark[y] ~= f then mark[y] = f; R[y].members = R[y].members + 1; qn = qn + 1; queue[qn] = y end
      for _, y2 in ipairs(rx.codry or E0) do
        if mark[y2] ~= f then mark[y2] = f; R[y2].members = R[y2].members + 1; qn = qn + 1; queue[qn] = y2 end
      end
    end
  end
  local mixbuses, F = {}, #feeders
  for k = 1, n do
    local r = R[k]
    if F >= RO.MIXBUS_MIN and r.members >= RO.MIXBUS_SHARE * F and reach[k] and not r.user
       and (r.role == "bus" or r.role == "passthrough" or r.role == "return") then
      r.reason = ("mix bus: holds %d of %d %s; "):format(r.members, F, basis) .. r.reason
      r.was, r.role = r.role, "mixbus"
      mixbuses[#mixbuses + 1] = k
    end
  end

  -- Main-path chain, group (just under the nearest mix bus, or the master) and level.
  local stamp = {}
  for k = 1, n do
    local r = R[k]
    stamp[k] = k
    local x = r.dry
    while x and x > 0 do
      if stamp[x] == k then flag(k, "feedback"); break end
      stamp[x] = k
      r.path[#r.path + 1] = x
      x = R[x].dry
    end
    r.reach = reach[k] or false
    if r.role ~= "ignored" and r.role ~= "mixbus" then
      local top = #r.path -- the group's place on the path; 0 = the track itself
      for i = 1, #r.path do if R[r.path[i]].role == "mixbus" then top = i - 1 break end end
      r.group = top == 0 and k or r.path[top]
      local lv = 0
      for i = 1, top do if R[r.path[i]].role ~= "passthrough" then lv = lv + 1 end end
      r.level = lv
    end
  end

  for k = 1, n do -- a layer belongs where the track it layers belongs
    local r = R[k]
    if r.role == "layer" then
      local g = R[r.layer_of].group
      r.group = (g and g > 0) and g or r.layer_of
    end
  end

  local out = { v = 1, mixbuses = mixbuses, feeders = F, basis = basis, tracks = {} }
  for k = 1, n do
    local r = R[k]
    out.tracks[k] = { role = r.role, kind = r.kind, reason = r.reason, flags = r.flags, dry = r.dry, path = r.path,
                      group = r.group, level = r.level, members = r.members, reach = r.reach, layer_of = r.layer_of,
                      via = r.dry_how }
  end
  return out
end

return RO
