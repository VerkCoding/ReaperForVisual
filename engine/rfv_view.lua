-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- View sets (roadmap step 6): what the user chose to see, as changes to a .rfv.json document
-- (spec/rfv-json.md), and the stage that follows from it. Pure Lua: the actions, the engine and
-- the tests all use it; rfv_store.lua reads and writes the document.
--
-- Decisions (owner, 2026-10-13; DESIGN.md "Decisions for step 6"):
--   * Show selected replaces the chosen tracks only; groups stay in the file and show again
--     when their members are chosen.
--   * A display-only group is one object whose X and Z come from its members' heard powers
--     added up; it opens to show them.
--   * The master track is never chosen; a new group is named from its members' common name.
--
-- Changes (all take the document and GUID lists; GUIDs are compared upper-case):
--   V.show(doc, guids)            the chosen tracks become exactly these; mode "chosen"
--   V.add(doc, guids)             add them; mode "chosen" (so the change shows)
--   V.remove(doc, guids)          take them out; mode "chosen"
--   V.group(doc, guids, names)    one new group of these tracks, taken out of any other group,
--                                 and chosen; returns its name
--   V.ungroup(doc, i)             remove group i (its tracks stay chosen)
--   V.rename(doc, i, name)
--   V.mode(doc, m)                "all", "chosen", or "toggle"
--   V.role(doc, guid, r)          override the role ("source", "bus", "return", "ignore",
--                                 "layer:<GUID>"); nil goes back to the routing's answer
--   V.path(doc, guid, dest)       choose a main path; nil goes back to the routing's choice
--   V.forget(doc, guids)          drop every mention of these tracks (deleted ones)
--
-- The stage: V.stage(tracks, doc) with tracks[k] = { guid, role, group, path } (the
-- classifier's result plus the GUID, in track order) returns a flat list of objects, each
--   { kind = "track" | "return" | "bus" | "group", track = k (not for a group), parent = index
--     of the object holding it (nil at the top), open = true when others hang under it;
--     a group also: gi (its index in doc.groups), name, members = { k, ... };
--     sum = { k, ... } when its X and Z are tracks added up (see V.object_powers) }
-- in track order (a group where its first member is), parents before their children.
--   mode "chosen": every chosen track is an object. One that belongs to a display group hangs
--     under the group's object; otherwise under the nearest chosen bus above it on its main
--     path, if any, so nested buses nest. A chosen bus with nothing under it is drawn closed,
--     measured at its output; open, it is the container of what hangs under it. A display
--     group adds up only its members that no other member carries (a bus already holds its
--     tracks: counting them again read +1.76 dB in the step 6 review).
--   mode "all": the whole mix at the default level (decision 1-A of step 4): one closed object
--     per group just under the mix bus, and every return (reverb, delay, parallel bus) its own
--     object wherever it sits (owner, step 6 review, U2-a: a folder of returns is a place to
--     keep them, not a sound). A group that holds returns is the rest of it, its other tracks
--     added up; a group left with nothing (a folder of returns only) is not drawn. That sum
--     leaves out sends into the group's buses from outside it and a folder's own items, which
--     only its meter holds. Display groups are not used there.
--
-- Undo (step 6 review, U1): V.snapshot(doc) is the choices as text (nil doc: nothing chosen),
-- V.restore(doc, text) puts them back; the engine keeps the history.

local J = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "rfv_json.lua")

local V = {}
V.ROLES = { source = true, bus = true, ["return"] = true, ignore = true }

local function up(g) return tostring(g):upper() end

local function list(doc_list)
  local out, seen = {}, {}
  for _, g in ipairs(doc_list or {}) do g = up(g); if not seen[g] then seen[g] = true; out[#out + 1] = g end end
  return out, seen
end

local function chosen_list(doc)
  doc.view = doc.view or J.object{}
  doc.view.tracks = J.array(doc.view.tracks or {})
  return doc.view.tracks
end

function V.show(doc, guids)
  local t = list(guids)
  doc.view = doc.view or J.object{}
  doc.view.tracks, doc.view.mode = J.array(t), "chosen"
end

function V.add(doc, guids)
  local cur, seen = list(chosen_list(doc))
  for _, g in ipairs(guids) do g = up(g); if not seen[g] then seen[g] = true; cur[#cur + 1] = g end end
  doc.view.tracks, doc.view.mode = J.array(cur), "chosen"
end

function V.remove(doc, guids)
  local drop = {}
  for _, g in ipairs(guids) do drop[up(g)] = true end
  local keep = {}
  for _, g in ipairs(chosen_list(doc)) do if not drop[up(g)] then keep[#keep + 1] = up(g) end end
  doc.view.tracks, doc.view.mode = J.array(keep), "chosen"
end

-- The common name of a group's members: their longest common prefix, cut back to a word and
-- without trailing numbers or separators ("Gtr L", "Gtr R" -> "Gtr"; "BV 1".."BV 5" -> "BV").
-- Bytes of letters: ASCII letters and digits, and every byte of a multi-byte UTF-8 character
-- (accented letters among them).
local WORD = "[%w\128-\255]"
function V.common_name(names)
  local p
  for _, n in ipairs(names) do
    n = tostring(n or "")
    if not p then p = n else
      local i = 0
      while i < #p and i < #n and p:sub(i + 1, i + 1):lower() == n:sub(i + 1, i + 1):lower() do i = i + 1 end
      p = p:sub(1, i)
    end
  end
  p = p or ""
  -- never end inside a UTF-8 character: drop continuation bytes and the lead byte before them
  while #p > 0 do
    local b = p:byte(#p)
    if b >= 0xC0 then p = p:sub(1, -2) -- a lead byte whose character was cut
    elseif b >= 0x80 then
      local j = #p
      while j > 0 and p:byte(j) >= 0x80 and p:byte(j) < 0xC0 do j = j - 1 end
      local lead = j > 0 and p:byte(j) or 0
      local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
      if #p - j + 1 == need then break end
      p = p:sub(1, j - 1)
    else break end
  end
  if #names > 1 then
    local whole = true -- the prefix ends inside a word: go back to its start
    for _, n in ipairs(names) do
      local nx = tostring(n or ""):sub(#p + 1, #p + 1)
      if nx ~= "" and nx:match(WORD) and p:sub(-1):match(WORD) then whole = false end
    end
    if not whole then p = p:gsub(WORD .. "+$", "") end
  end
  p = p:gsub("[%s%d%p]+$", ""):gsub("^[%s%p]+", "")
  return p
end

function V.group(doc, guids, names)
  local members = list(guids)
  if #members == 0 then return nil end
  local take = {}
  for _, g in ipairs(members) do take[g] = true end
  local groups = {}
  for _, grp in ipairs(doc.groups or {}) do
    local keep = {}
    for _, g in ipairs(grp.tracks or {}) do if not take[up(g)] then keep[#keep + 1] = up(g) end end
    if #keep > 0 then grp.tracks = J.array(keep); groups[#groups + 1] = grp end
  end
  local name = V.common_name(names or {})
  if #name < 2 then name = "Group " .. (#groups + 1) end
  local base, k = name, 2
  local taken = {}
  for _, grp in ipairs(groups) do taken[tostring(grp.name)] = true end
  while taken[name] do name = base .. " " .. k; k = k + 1 end
  groups[#groups + 1] = J.object{ name = name, tracks = J.array(members) }
  doc.groups = J.array(groups)
  V.add(doc, members)
  return name
end

function V.ungroup(doc, i)
  local groups = {}
  for k, grp in ipairs(doc.groups or {}) do if k ~= i then groups[#groups + 1] = grp end end
  doc.groups = J.array(groups)
end

function V.rename(doc, i, name)
  local grp = (doc.groups or {})[i]
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if grp and name ~= "" then grp.name = name; return true end
  return false
end

function V.mode(doc, m)
  doc.view = doc.view or J.object{}
  if m == "toggle" then m = doc.view.mode == "all" and "chosen" or "all" end
  if m ~= "all" and m ~= "chosen" then return false end
  doc.view.mode = m
  return true
end

function V.role(doc, guid, r)
  if r ~= nil then
    r = tostring(r)
    if not (V.ROLES[r] or r:match("^layer:{[%x%-]+}$")) then return false end
    if r:sub(1, 6) == "layer:" then r = "layer:" .. up(r:sub(7)) end
  end
  doc.roles = doc.roles or J.object{}
  doc.roles[up(guid)] = r
  return true
end

function V.path(doc, guid, dest)
  doc.paths = doc.paths or J.object{}
  doc.paths[up(guid)] = dest and up(dest) or nil
  return true
end

function V.forget(doc, guids)
  local drop = {}
  for _, g in ipairs(guids) do drop[up(g)] = true end
  local keep = {}
  for _, g in ipairs(chosen_list(doc)) do if not drop[up(g)] then keep[#keep + 1] = up(g) end end
  doc.view.tracks = J.array(keep)
  local groups = {}
  for _, grp in ipairs(doc.groups or {}) do
    local t = {}
    for _, g in ipairs(grp.tracks or {}) do if not drop[up(g)] then t[#t + 1] = up(g) end end
    if #t > 0 then grp.tracks = J.array(t); groups[#groups + 1] = grp end
  end
  doc.groups = J.array(groups)
  for g in pairs(drop) do
    if doc.roles then doc.roles[g] = nil end
    if doc.paths then doc.paths[g] = nil end
  end
  for g, r in pairs(doc.roles or {}) do -- a layer of a forgotten track has nothing to belong to
    if type(r) == "string" and drop[r:sub(7):upper()] and r:sub(1, 6) == "layer:" then doc.roles[g] = nil end
  end
end

local BUSLIKE = { bus = true, passthrough = true, mixbus = true }

function V.stage(tracks, doc)
  local n = #tracks
  local index = {}
  for k = 1, n do index[up(tracks[k].guid)] = k end
  local function kind(k)
    local r = tracks[k].role
    return BUSLIKE[r] and "bus" or (r == "return" and "return" or "track")
  end
  local mode = doc and doc.view and doc.view.mode or "chosen"
  if mode == "all" then
    -- the buses that carry a return on their way down (a return's main path, up to its group)
    local holds, kids = {}, {}
    for k = 1, n do
      local t = tracks[k]
      local d = t.path and t.path[1]
      if d then kids[d] = kids[d] or {}; table.insert(kids[d], k) end
      if t.role == "return" and t.group and t.group > 0 and t.group ~= k then
        for _, b in ipairs(t.path or {}) do
          holds[b] = true
          if b == t.group then break end
        end
      end
    end
    local function rest(b, out) -- what b carries besides returns, as tracks to add up
      for _, k in ipairs(kids[b] or {}) do
        if tracks[k].role ~= "return" then
          if holds[k] then rest(k, out) else out[#out + 1] = k end
        end
      end
      return out
    end
    local objs, seen = {}, {}
    for k = 1, n do
      local t = tracks[k]
      local g = t.group
      if g and g > 0 and not seen[g] and tracks[g] and tracks[g].role ~= "mixbus" then
        seen[g] = true
        if holds[g] and tracks[g].role ~= "return" then
          local sum = rest(g, {})
          table.sort(sum)
          if #sum > 0 then objs[#objs + 1] = { kind = kind(g), track = g, sum = sum } end
        else
          objs[#objs + 1] = { kind = kind(g), track = g }
        end
      end
      if t.role == "return" and g and g > 0 and g ~= k then objs[#objs + 1] = { kind = "return", track = k } end
    end
    table.sort(objs, function(a, b) return a.track < b.track end)
    return objs, "all"
  end
  local chosen = {}
  for _, g in ipairs(doc and doc.view and doc.view.tracks or {}) do
    local k = index[up(g)]
    if k then chosen[k] = true end
  end
  -- display groups: a chosen track belongs to the first group that names it
  local in_group, gobj = {}, {}
  for gi, grp in ipairs(doc and doc.groups or {}) do
    local members = {}
    for _, g in ipairs(grp.tracks or {}) do
      local k = index[up(g)]
      if k and chosen[k] and not in_group[k] then in_group[k] = gi; members[#members + 1] = k end
    end
    if #members > 0 then
      table.sort(members)
      -- added up: the members no other member carries on its main path
      local inside, sum = {}, {}
      for _, k in ipairs(members) do inside[k] = true end
      for _, k in ipairs(members) do
        local carried = false
        for _, b in ipairs(tracks[k].path or {}) do if inside[b] then carried = true; break end end
        if not carried then sum[#sum + 1] = k end
      end
      gobj[gi] = { kind = "group", gi = gi, name = tostring(grp.name or ("Group " .. gi)), members = members, sum = sum, at = members[1] }
    end
  end
  -- every chosen track; outside groups, held by the nearest chosen bus above it (also outside)
  local tobj = {}
  for k = 1, n do
    if chosen[k] then
      local o = { kind = kind(k), track = k, at = k }
      if in_group[k] then o.up = gobj[in_group[k]]
      else
        for _, b in ipairs(tracks[k].path or {}) do
          if chosen[b] and not in_group[b] then o.upk = b; break end
        end
      end
      tobj[k] = o
    end
  end
  for _, o in pairs(tobj) do if o.upk then o.up = tobj[o.upk]; o.upk = nil end end
  -- order: parents first, then track order (a group where its first member is)
  local all = {}
  for _, o in pairs(gobj) do all[#all + 1] = o end
  for _, o in pairs(tobj) do all[#all + 1] = o end
  local function key(o) -- the chain of positions from the top: sorts children right after parents
    local chain, x = {}, o
    while x do table.insert(chain, 1, { x.at, x.kind == "group" and 0 or 1 }); x = x.up end
    return chain
  end
  local keys = {}
  for _, o in ipairs(all) do keys[o] = key(o) end
  table.sort(all, function(a, b)
    local ka, kb = keys[a], keys[b]
    for i = 1, math.min(#ka, #kb) do
      if ka[i][1] ~= kb[i][1] then return ka[i][1] < kb[i][1] end
      if ka[i][2] ~= kb[i][2] then return ka[i][2] < kb[i][2] end
    end
    return #ka < #kb
  end)
  local pos = {}
  for i, o in ipairs(all) do pos[o] = i end
  local objs = {}
  for i, o in ipairs(all) do
    objs[i] = { kind = o.kind, track = o.track, gi = o.gi, name = o.name, members = o.members, sum = o.sum, parent = o.up and pos[o.up] or nil }
  end
  for _, o in ipairs(objs) do if o.parent then objs[o.parent].open = true end end
  return objs, "chosen"
end

-- The heard powers of an object, from each track's heard powers h[k] = { pl, pr } (or nil): a
-- track, return or bus is its own track; a group, or a group without its returns, adds up the
-- tracks in its sum. nil when nothing sounds.
function V.object_powers(o, h)
  local list = o.sum or (o.kind == "group" and o.members)
  if not list then return h[o.track] end
  local pl, pr, any = 0, 0, false
  for _, k in ipairs(list) do
    local p = h[k]
    if p then pl, pr, any = pl + p[1], pr + p[2], true end
  end
  return any and { pl, pr } or nil
end

-- The choices of a document as text (keys sorted, so equal choices give equal text), and back.
V.CHOICES = { "view", "groups", "roles", "paths", "sections" }
function V.snapshot(doc)
  local t = J.object{}
  for _, key in ipairs(V.CHOICES) do t[key] = doc and doc[key] or J.null end
  return J.encode(t)
end
function V.restore(doc, text)
  local t = J.decode(text)
  for _, key in ipairs(V.CHOICES) do
    local v = t[key]
    if J.is_null(v) then v = nil end
    doc[key] = v
  end
end

return V
