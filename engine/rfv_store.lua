-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The user's choices for a project, keyed by track GUID (format: spec/rfv-json.md).
--
-- Where they live:
--   saved project    "<project>.rfv.json" beside the .rpp
--   unsaved project  non-persistent ExtState, one key per project tab, until the first save
-- Every script (the engine, each action) keeps only a cache in its own state table `st`.
-- S.edit always reads the latest copy, applies the change and writes it back at once, so two
-- scripts, or a file synced by another program, never overwrite each other's changes.
-- Nothing here touches the project itself.

local J = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "rfv_json.lua")

local S = {}
S.FORMAT, S.VERSION = "rfv", 0
S.EXT_SECTION = "ReaperForVisual"
local ITEM_SAMPLE = 32      -- item GUIDs kept to recognise the same project later
local SAME_TRACKS, SAME_ITEMS = 0.9, 0.5

-- paths ----------------------------------------------------------------------------------

-- "D:/x/Song.rpp" -> "D:/x/Song.rfv.json"; nil for a project never saved.
function S.sidecar_path(rpp)
  if not rpp or rpp == "" then return nil end
  return (rpp:gsub("%.[Rr][Pp][Pp]$", "")) .. ".rfv.json"
end

-- REAPER's timestamped backups, the MCP server's backups and .rpp-bak files: opening one
-- must not leave a new .rfv.json beside it unless the user changes something there.
function S.is_backup_path(rpp)
  local l = (rpp or ""):lower()
  return l:find("[/\\]backups[/\\]") ~= nil or l:find("%.mcp%-backup%-") ~= nil or not l:find("%.rpp$")
end

local function slurp(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function exists(p) return reaper.file_exists(p) end

-- documents ------------------------------------------------------------------------------

function S.new_doc()
  return J.object{ format = S.FORMAT, version = S.VERSION, view = J.object{ mode = "chosen", tracks = J.array{} },
                   groups = J.array{}, roles = J.object{}, sections = J.object{ source = "regions" } }
end

-- Upper-case GUIDs, one group per track (the first wins), a known view mode.
local function normalize(doc)
  doc.view = type(doc.view) == "table" and doc.view or J.object{}
  if doc.view.mode ~= "all" then doc.view.mode = "chosen" end
  doc.view.tracks = type(doc.view.tracks) == "table" and doc.view.tracks or J.array{}
  for i, g in ipairs(doc.view.tracks) do doc.view.tracks[i] = tostring(g):upper() end
  local groups, seen = J.array{}, {}
  for _, grp in ipairs(type(doc.groups) == "table" and doc.groups or {}) do
    if type(grp) == "table" then
      local keep = J.array{}
      for _, g in ipairs(type(grp.tracks) == "table" and grp.tracks or {}) do
        g = tostring(g):upper()
        if not seen[g] then seen[g] = true; keep[#keep + 1] = g end
      end
      grp.tracks = keep
      groups[#groups + 1] = grp
    end
  end
  doc.groups = groups
  local roles = J.object{}
  for g, r in pairs(type(doc.roles) == "table" and doc.roles or {}) do
    if type(r) == "string" and r:sub(1, 6) == "layer:" then r = "layer:" .. r:sub(7):upper() end
    roles[tostring(g):upper()] = r
  end
  doc.roles = roles
  if type(doc.paths) == "table" then -- optional: the main path the user chose for a track whose sends tie
    local paths = J.object{}
    for g, d in pairs(doc.paths) do if type(d) == "string" then paths[tostring(g):upper()] = d:upper() end end
    doc.paths = paths
  end
  doc.sections = type(doc.sections) == "table" and doc.sections or J.object{ source = "regions" }
  return doc
end

-- text -> doc, or nil and an error { code = "damaged" | "foreign" | "newer", msg }
function S.decode(text)
  local doc, err = J.decode(text)
  if not doc then return nil, { code = "damaged", msg = err } end
  if type(doc) ~= "table" or doc.format ~= S.FORMAT then return nil, { code = "foreign", msg = "not an .rfv.json document" } end
  if type(doc.version) ~= "number" then return nil, { code = "damaged", msg = "no version" } end
  if doc.version > S.VERSION then
    return nil, { code = "newer", msg = ("written by a newer ReaperForVisual (format version %s); update it to change these choices"):format(tostring(doc.version)) }
  end
  return normalize(doc)
end

-- Reads a sidecar. If a write was cut short (file gone, .tmp or .old left), recovers from
-- those. Returns doc, text, err, recovered_from.
function S.read(path)
  local text, from = slurp(path), nil
  if not text then
    for _, alt in ipairs({ path .. ".tmp", path .. ".old" }) do
      local t = slurp(alt)
      if t and S.decode(t) then text, from = t, alt; break end
    end
  end
  if not text then return nil, nil, { code = "missing" } end
  local doc, err = S.decode(text)
  return doc, text, err, from
end

-- Write through a temporary file; the old file is moved aside first, because Windows will
-- not rename onto an existing file. A crash at any point leaves path, .tmp or .old readable.
function S.write(path, text)
  local tmp, old = path .. ".tmp", path .. ".old"
  local f, err = io.open(tmp, "wb")
  if not f then return false, { code = "write-failed", msg = "cannot write " .. tmp .. ": " .. tostring(err) } end
  f:write(text)
  f:close()
  if exists(path) then
    os.remove(old)
    local ok, e = os.rename(path, old)
    if not ok then os.remove(tmp); return false, { code = "write-failed", msg = "cannot replace " .. path .. ": " .. tostring(e) } end
  end
  local ok, e = os.rename(tmp, path)
  if not ok then
    os.rename(old, path)
    return false, { code = "write-failed", msg = "cannot write " .. path .. ": " .. tostring(e) }
  end
  os.remove(old)
  return true
end

-- Keep a damaged file under a name that is not taken yet. Returns the new name.
function S.keep_damaged(path)
  local name = path .. ".bad"
  if exists(name) then
    local base = path .. ".bad-" .. os.date("%Y%m%d-%H%M%S")
    name = base
    local n = 2
    while exists(name) do name = base .. "-" .. n; n = n + 1 end
  end
  local ok, e = os.rename(path, name)
  if not ok then return nil, e end
  return name
end

-- the project ----------------------------------------------------------------------------

-- Full path of the project's .rpp, or "" when it was never saved.
function S.project_file(proj)
  local i = 0
  while true do
    local p, fn = reaper.EnumProjects(i)
    if not p then return "" end
    if p == proj then return fn or "" end
    i = i + 1
  end
end

function S.tab_key(proj) return "unsaved " .. tostring(proj) end

local function item_guid(it) local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false); return g end

-- What identifies a project's content: all track GUIDs and a spread sample of item GUIDs.
-- Songs made from one template share track GUIDs but not item GUIDs.
function S.fingerprint(proj)
  local tracks, n = {}, reaper.CountTracks(proj)
  for i = 0, n - 1 do tracks[reaper.GetTrackGUID(reaper.GetTrack(proj, i))] = true end
  local items, ni = J.array{}, reaper.CountMediaItems(proj)
  local step = math.max(1, ni / ITEM_SAMPLE)
  local k = 0
  while k < ni and #items < ITEM_SAMPLE do items[#items + 1] = item_guid(reaper.GetMediaItem(proj, math.floor(k))); k = k + step end
  return { tracks = tracks, ntracks = n, items = items, nitems = ni }
end

local function item_set(proj)
  local set = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do set[item_guid(reaper.GetMediaItem(proj, i))] = true end
  return set
end

local function frac(list, set)
  if #list == 0 then return nil end
  local hit = 0
  for _, g in ipairs(list) do if set[g] then hit = hit + 1 end end
  return hit / #list
end

local function items_agree(sample, proj)
  local f = frac(sample, item_set(proj))
  if f == nil then return reaper.CountMediaItems(proj) == 0 end -- neither has items
  return f >= SAME_ITEMS
end

-- Is the project in this tab still the one the fingerprint was taken of (Save As)?
function S.same_content(fp, proj)
  if not fp then return false end
  local list = {}
  for g in pairs(fp.tracks) do list[#list + 1] = g end
  local now = S.fingerprint(proj).tracks
  local f = frac(list, now)
  return (f == nil and reaper.CountTracks(proj) == 0 or (f or 0) >= SAME_TRACKS) and items_agree(fp.items, proj)
end

local function referenced(doc)
  local g, list = {}, {}
  local function add(x) if not g[x] then g[x] = true; list[#list + 1] = x end end
  for _, x in ipairs(doc.view and doc.view.tracks or {}) do add(x) end
  for _, grp in ipairs(doc.groups or {}) do for _, x in ipairs(grp.tracks or {}) do add(x) end end
  for x in pairs(doc.roles or {}) do add(x) end
  for x in pairs(doc.paths or {}) do add(x) end
  return list
end

-- Does a document belong to the project in this tab? Its tracks must be here, and the item
-- sample it was written with must be here too.
function S.doc_matches(doc, proj)
  local refs = referenced(doc)
  if #refs == 0 then return #(doc.items or {}) > 0 and items_agree(doc.items, proj) end
  local f = frac(refs, S.fingerprint(proj).tracks)
  return (f or 0) >= 0.5 and items_agree(doc.items or {}, proj)
end

-- GUIDs the document names that are not tracks of this project (deleted, or never here).
function S.missing(doc, proj)
  local here, out = S.fingerprint(proj).tracks, {}
  for _, g in ipairs(referenced(doc)) do if not here[g] then out[#out + 1] = g end end
  return out
end

-- Other .rfv.json files in the project's folder whose choices fit this project, best first:
-- after a Save As made while the tool was not running, or a renamed .rpp.
function S.adoption_candidates(proj)
  local fn = S.project_file(proj)
  if fn == "" then return {} end
  local dir = fn:match("^(.*)[/\\]")
  local own = S.sidecar_path(fn)
  local out = {}
  reaper.EnumerateFiles(dir, -1) -- refresh REAPER's cached listing
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    i = i + 1
    local path = dir .. package.config:sub(1, 1) .. name
    if name:lower():find("%.rfv%.json$") and path ~= own then
      local doc = S.read(path)
      if doc and S.doc_matches(doc, proj) then
        local refs = referenced(doc)
        out[#out + 1] = { path = path, project = doc.project, tracks = #refs - #S.missing(doc, proj) }
      end
    end
  end
  table.sort(out, function(a, b) return a.tracks > b.tracks end)
  return out
end

-- reading and editing ----------------------------------------------------------------------

-- Where this project's choices live now: "file", path  or  "ext", key
local function location(proj)
  local fn = S.project_file(proj)
  if fn ~= "" then return "file", S.sidecar_path(fn), fn end
  return "ext", S.tab_key(proj), fn
end

local function load(where, key)
  if where == "file" then
    local doc, text, err, from = S.read(key)
    if doc and from then S.write(key, text) end -- put the recovered copy back under its name
    return doc, text, err, from
  end
  local text = reaper.GetExtState(S.EXT_SECTION, key)
  if text == "" then return nil, nil, { code = "missing" } end
  local doc, err = S.decode(text)
  return doc, text, err
end

local function store(where, key, text)
  if where == "file" then return S.write(key, text) end
  reaper.SetExtState(S.EXT_SECTION, key, text, false)
  return true
end

-- Labels, the project's file name and an item sample: for people reading the file and for
-- recognising the project later. Never used to match tracks.
local function stamp(doc, proj, fn)
  local by = {}
  local master = reaper.GetMasterTrack(proj)
  by[reaper.GetTrackGUID(master)] = master
  for i = 0, reaper.CountTracks(proj) - 1 do local t = reaper.GetTrack(proj, i); by[reaper.GetTrackGUID(t)] = t end
  local labels = J.object{}
  for _, g in ipairs(referenced(doc)) do
    if by[g] then local _, nm = reaper.GetTrackName(by[g]); labels[g] = nm end
  end
  doc.labels = labels
  doc.items = S.fingerprint(proj).items
  doc.project = fn ~= "" and fn:match("[^/\\]+$") or J.null
end

local function encode(doc) return J.encode(doc, "  ") .. "\n" end

-- Write st's document where the project now keeps it (used when following a Save As).
local function persist(proj, st)
  local where, key, fn = location(proj)
  stamp(st.doc, proj, fn)
  local text = encode(st.doc)
  local ok, err = store(where, key, text)
  if ok then st.text, st.error, st.virtual = text, nil, nil else st.error = err end
  return ok
end

-- S.edit(proj, st, fn): change the choices. Reads the latest copy, calls fn(doc), writes.
-- Returns true, or false and an error { code, msg }. Refused for a file from a newer version.
-- A damaged file is kept under a free ".bad" name first (st.kept_as tells where).
function S.edit(proj, st, fn)
  if st.error and st.error.code == "newer" then return false, st.error end
  local where, key, file = location(proj)
  local doc, _, err = load(where, key)
  if err and err.code == "newer" then st.error = err; return false, err end
  if err and (err.code == "damaged" or err.code == "foreign") and where == "file" then
    local kept, kerr = S.keep_damaged(key)
    if not kept then st.error = { code = "write-failed", msg = "cannot move the damaged file aside: " .. tostring(kerr) }; return false, st.error end
    st.kept_as = kept
  end
  doc = doc or S.new_doc()
  fn(doc)
  normalize(doc)
  stamp(doc, proj, file)
  local text = encode(doc)
  local ok, werr = store(where, key, text)
  if not ok then st.error = werr; return false, werr end
  st.doc, st.text, st.error, st.virtual, st.file = doc, text, nil, nil, file
  return true
end

-- S.follow(proj, st): keep st in step with the project; call it about once a second.
-- Returns what happened:
--   "loaded"          first look (st.doc may stay nil: nothing chosen yet)
--   "same"            nothing changed
--   "reloaded"        another script or program changed the choices; st.doc is new
--   "first-save"      the project got a file name; the unsaved choices were moved into it
--   "save-as"         same project under a new name; the choices were copied to it
--   "save-as-backup"  the new name is a backup; the choices are shown but not written there
--   "loaded-existing" the new name already had choices, now in use
--   "other-project"   a different project in this tab; st.doc dropped
-- st.error = { code, msg } when the choices cannot be read or written: "damaged", "foreign",
-- "newer" (read only until the tool is updated), "write-failed". st.recovered_from names
-- the .tmp or .old a cut-short write was recovered from.
function S.follow(proj, st)
  local where, key, fn = location(proj)
  local count = reaper.GetProjectStateChangeCount(proj)

  local function take(doc, text, err, from)
    st.doc, st.text, st.error, st.recovered_from = doc, text, (err and err.code ~= "missing") and err or nil, from
  end

  if st.file == nil or fn ~= st.file then
    local first, before, prevdoc, prevfile = st.file == nil, st.fp, st.doc, st.file
    st.file = fn
    local doc, text, err, from = load(where, key)
    if where == "ext" and doc and not S.doc_matches(doc, proj) then
      -- choices left by an earlier unsaved project in this tab
      reaper.DeleteExtState(S.EXT_SECTION, key, false)
      doc, text, err = nil, nil, { code = "missing" }
    end
    local ev
    if doc or (err and err.code ~= "missing") then
      take(doc, text, err, from)
      ev = first and "loaded" or "loaded-existing"
    elseif where == "file" then
      -- nothing beside this file yet: is it the unsaved project of this tab, just saved?
      local udoc = load("ext", S.tab_key(proj))
      if udoc and S.doc_matches(udoc, proj) then
        st.doc = udoc
        if persist(proj, st) then reaper.DeleteExtState(S.EXT_SECTION, S.tab_key(proj), false) end
        ev = "first-save"
      elseif not first and prevdoc and S.same_content(before, proj) then
        st.doc = prevdoc
        if S.is_backup_path(fn) then st.virtual = true; st.text = nil; ev = "save-as-backup"
        else persist(proj, st); ev = (prevfile == "") and "first-save" or "save-as" end
      else
        take(nil, nil, nil); ev = first and "loaded" or "other-project"
      end
    else
      take(nil, nil, nil); ev = first and "loaded" or "other-project"
    end
    st.fp, st.fp_count = S.fingerprint(proj), count
    return ev
  end

  -- same name: pick up changes made elsewhere
  if not st.virtual then
    local text = where == "file" and slurp(key) or reaper.GetExtState(S.EXT_SECTION, key)
    if text == "" then text = nil end
    if text ~= st.text then
      local doc, _, err, from = load(where, key)
      take(doc, text, err, from)
      if count ~= st.fp_count then st.fp, st.fp_count = S.fingerprint(proj), count end
      return "reloaded"
    end
  end
  if count ~= st.fp_count then st.fp, st.fp_count = S.fingerprint(proj), count end
  return "same"
end

S.json = J
return S
