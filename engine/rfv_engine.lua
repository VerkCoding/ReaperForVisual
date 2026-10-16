-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The ReaperForVisual engine: a read-only defer loop that follows the active project tab and
-- publishes what it reads to REAPER's non-persistent ExtState, where the page reads it through
-- the web interface (/_/GET/EXTSTATE/ReaperForVisual/<key>).
--
--   graph  structure: tab, project, tracks (GUID, name, colour, parent, and the role each one
--          plays in the mix), the user's choices and storage errors. Rewritten only when it
--          changes; "gseq" counts the versions.
--   frame  ten times a second: sequence number, state, transport, the engine's own cost, the
--          last error, each track's own X (azimuth, degrees) and Z (level, dB) from
--          engine/rfv_meter.lua in graph order, and where it is heard once its buses have
--          carried it (engine/rfv_heard.lua). Raw peaks left the frame in step 5: X and Z say
--          more, and formatting 448 numbers cost a third of a frame at 224 tracks.
--
-- Rules, each measured on REAPER 7.82 (DESIGN.md):
--   * a defer loop never gets an automatic undo point, even with the user's unrecorded change
--     pending, so the engine never touches undo, selection, the cursor or the project;
--   * set_action_options(1|4): running the action again stops the loop without a dialog and
--     lights its toolbar button while it runs;
--   * every tick runs under xpcall, so an error never reaches REAPER's error dialog;
--   * a frame stays small (the web interface needs ~16 ms for 4.5 KB, 62 ms for 20 KB).
-- Besides ExtState it writes only the user's choices (through rfv_store.lua, on a command from
-- the page) and the light of the "Show all or chosen tracks" action (on while the active tab
-- shows the whole mix): neither is part of the project.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local CORE = dofile(HERE .. "rfv_core.lua")
local J = dofile(HERE .. "rfv_json.lua")
local S = dofile(HERE .. "rfv_store.lua")
local SN = dofile(HERE .. "rfv_snapshot.lua")
local RO = dofile(HERE .. "rfv_roles.lua")
local MT = dofile(HERE .. "rfv_meter.lua")
local HD = dofile(HERE .. "rfv_heard.lua")
local V = dofile(HERE .. "rfv_view.lua")
local AC = dofile(HERE .. "rfv_actions.lua")
local SP = dofile(HERE .. "rfv_spectrum.lua")
local YM = dofile(HERE .. "rfv_ymap.lua")
local LN = dofile(HERE .. "rfv_learn.lua")
local SC = dofile(HERE .. "rfv_sections.lua")
assert(LN.BLOCK == YM.BLOCK, "the learning and the spectrum map must share their blocks") -- a section's blocks that played

local E = {}
E.SECTION = "ReaperForVisual"
E.VERSION = CORE.VERSION

local PUBLISH_EVERY = 0.1   -- frame rate of the page
local STORE_EVERY = 1.0     -- re-read the user's choices
local GRAPH_EVERY = 0.5     -- at most two structure rebuilds a second
local PRUNE_EVERY = 5.0     -- forget closed tabs
local SNAP_EVERY = 2.0      -- look at the routing at least this often: arm, monitoring and other
                            -- changes that make no undo point do not move the state counter
local CACHE_EVERY = 10.0    -- read each track's envelopes, sends and VCA groups again at least this
                            -- often (and whenever the state counter moves: adding an envelope, a
                            -- send or a group membership makes an undo point)
local NET_PEAK = 0.001      -- meter safety net: a track "silent by routing" heard above -60 dBFS
local NET_FRAMES = 5        -- ... in this many frames (half a second) becomes a source
local NET_RELEASE = 30.0    -- ... and is let go after this many seconds of playing without a sound
                            -- (step 10a: a generator switched off stayed a source for the session)
local REFRESH = 0.04716     -- the meter's refresh, until measured (REAPER 7.82: 47.16 ms)
local COST_WINDOW = 300     -- ticks kept for the cost figures (~10 s)
local MAX_ERRORS = 20       -- errors in a row before the engine gives up
local UNDO_MAX = 20         -- earlier choices kept per tab for the page's Undo (in memory only)
local Y_BUDGET = 0.0015     -- seconds per tick at most for the spectrum map (step 7)
local TICK_TARGET = 0.002   -- the map gets what is left of this, after the cycle's other work
local Y_SPAN = YM.SPAN       -- seconds of the files behind Y and width, as Z's window
local Y_EVERY = 0.2         -- seconds between two workings-out of Y and width
local SECT_EVERY = 0.5      -- seconds between two sections' average stages (step 9b: one took
                            -- 3.4-6.3 ms at 224 tracks; eight are each new every 4 s)
local STOP_REFRESH = 2.0    -- stopped, the stage worked out again at least this often (step 10a): a send
                            -- or a pan mode set by a script moves no state counter

local function now() return reaper.time_precise() end
-- The ExtState section this engine writes to. Tests use their own, so they never touch an
-- engine the user is running; set by E.run.
local SEC = E.SECTION
local function setx(k, v) reaper.SetExtState(SEC, k, v, false) end
local function getx(k) return reaper.GetExtState(SEC, k) end

-- Is a page open? The page writes its epoch time in ms to "page_seen" every 2 s; one seen in
-- the last 10 s means the engine need not open another browser tab.
function E.page_recent(section)
  local v = tonumber(reaper.GetExtState(section or SEC, "page_seen"))
  if not v then return false end
  local age = os.time() * 1000 - v
  return age > -5000 and age < 10000
end

-- The section a page shows (step 9b review): the page writes "<ms>|<start>|<end>" to "page_sect"
-- every 2 s and when the choice changes ("<ms>|" for the stage at the cursor). The index of that
-- section in list, or nil (none, or written over 10 s ago).
function E.page_section(list, section)
  local v, a, b = reaper.GetExtState(section or SEC, "page_sect"):match("^(%d+)|([%d%.]+)|([%d%.]+)$")
  local age = v and os.time() * 1000 - tonumber(v)
  if not age or age <= -5000 or age >= 10000 then return nil end
  a, b = tonumber(a), tonumber(b)
  for i, x in ipairs(list or {}) do
    if math.abs(x.a - a) < 0.002 and math.abs(x.b - b) < 0.002 then return i end
  end
end

-- What to do when REAPER's web interface is off (step 11: before, a line in the ReaScript
-- console, easy to miss). Turning it on stays the user's: it opens a network port.
E.WEB_HELP = [[ReaperForVisual shows its stage in your web browser, through REAPER's web interface. The web interface is off.

Turn it on once:
1. In Preferences, scroll the list on the left down to Control/OSC/web (near its end).
2. Click Add.
3. Control surface mode: Web browser interface. Keep the port it offers.
4. Click OK, then OK again to close Preferences.
5. Run "ReaperForVisual - Start or stop" again.

Other computers on your network can open REAPER's web interface too; the same window lets you set a user name and password.

Open Preferences now?]]

-- Open REAPER's Preferences (the action's name is checked first: an ID that names something else
-- is never run).
function E.open_prefs()
  local id = 40016 -- Options: Preferences...
  local name = reaper.kbd_getTextFromCmd(id, nil) or ""
  if name:find("Preferences", 1, true) then reaper.Main_OnCommand(id, 0) end
end

-- Port of the first web interface in reaper.ini, or nil when none is configured.
function E.web_port()
  local f = io.open(reaper.get_ini_file(), "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  for line in text:gmatch("[^\r\n]+") do
    local port = line:match("^csurf_%d+%s*=%s*HTTP%s+%S+%s+(%d+)")
    if port then return tonumber(port) end
  end
  return nil
end

-- Open a URL in the default browser. SWS's CF_ShellExecute when present; otherwise the
-- system's opener through ExecProcess with -2 (no wait, minimized), so no console window
-- flashes up the way it does with os.execute.
function E.open_url(url)
  if reaper.CF_ShellExecute then return reaper.CF_ShellExecute(url) end
  local os_name = reaper.GetOS()
  if os_name:find("^Win") then
    reaper.ExecProcess('cmd.exe /C start "" "' .. url .. '"', -2)
  elseif os_name:find("^OSX") or os_name:find("^macOS") then
    reaper.ExecProcess('/usr/bin/open "' .. url .. '"', -2)
  else
    reaper.ExecProcess('xdg-open "' .. url .. '"', -2)
  end
end

local function num(x)
  if x == 0 then return "0" end
  return string.format("%.4g", x)
end

-- The meter's fall per second as set in REAPER (Preferences > Appearance > Meters), the
-- starting guess for the decay step until the readings measure it.
local function vudecay()
  local ok, v = reaper.get_config_var_string("vudecay")
  return ok and tonumber(v) or 30
end

-- The command of the "Show all or chosen tracks" action, from REAPER's key map (read once; 0
-- when it is not registered). The action also tells its command when it runs (ExtState
-- "all_cmd"), for one registered after the engine started.
function E.all_action_id()
  local f = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "rb")
  if not f then return 0 end
  local text = f:read("a")
  f:close()
  local rs = text:match('SCR %d+ 0 (RS%x+) "[^"\r\n]*" "?[^\r\n]*ReaperForVisual %- Show all or chosen tracks%.lua')
  return rs and reaper.NamedCommandLookup("_" .. rs) or 0
end

-- X and Z as JSON: [x,z], [null,z] without an image, null when silent.
local function axes_json(x, z)
  if not z then return "null" end
  return x and string.format("[%.1f,%.1f]", x, z) or string.format("[null,%.1f]", z)
end

-- What rarely changes about a track, read again when the project's state changes (at least
-- every CACHE_EVERY s):
-- pan mode and law, dual pans, its envelopes worth evaluating (active, with points), found by
-- listing them (reading only; a send's envelopes are on its track, with I_SEND_IDX = the send's
-- index + 1), its sends (index, destination, mode, channels), and its VCA groups.
local function track_cache(c, proj, tr)
  local st = c.ts[tr]
  if st and st.stamp == c.cache_t then return st end
  local function v(k) return reaper.GetMediaTrackInfo_Value(tr, k) end
  st = { stamp = c.cache_t, mode = v("I_PANMODE"), law = v("D_PANLAW"), dl = v("D_DUALPANL"), dr = v("D_DUALPANR"),
         env = {}, senv = {}, sends = {} }
  for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
    local env = reaper.GetTrackEnvelope(tr, i)
    if reaper.CountEnvelopePoints(env) > 0 then
      local ok, has, active = pcall(reaper.GetSetEnvelopeInfo_String, env, "ACTIVE", "", false)
      if not (ok and has and active == "0") then
        local _, name = reaper.GetEnvelopeName(env)
        local e = { env = env, smode = reaper.GetEnvelopeScalingMode(env) }
        local si = math.floor(reaper.GetEnvelopeInfo_Value(env, "I_SEND_IDX") + 0.5)
        if si > 0 then
          st.senv[si - 1] = st.senv[si - 1] or {}
          st.senv[si - 1][name] = e
        else
          st.env[name] = e
        end
      end
    end
  end
  if c.idx_t ~= c.cache_t then -- track pointer -> index, for send destinations
    c.idx, c.idx_t = {}, c.cache_t
    for i = 0, reaper.CountTracks(proj) - 1 do c.idx[tostring(reaper.GetTrack(proj, i))] = i + 1 end
  end
  for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    local function sv(k) return reaper.GetTrackSendInfo_Value(tr, 0, i, k) end
    st.sends[#st.sends + 1] = { i = i, dst = c.idx[tostring(sv("P_DESTTRACK"))], mode = math.floor(sv("I_SENDMODE")),
                                mute = sv("B_MUTE") ~= 0, srcchan = math.floor(sv("I_SRCCHAN")), dstchan = math.floor(sv("I_DSTCHAN")) }
  end
  st.follow = { reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_FOLLOW", 0, 0), reaper.GetSetTrackGroupMembershipHigh(tr, "VOLUME_VCA_FOLLOW", 0, 0) }
  st.lead = { reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_LEAD", 0, 0), reaper.GetSetTrackGroupMembershipHigh(tr, "VOLUME_VCA_LEAD", 0, 0) }
  c.ts[tr] = st
  return st
end

-- An envelope's value at pos (nil if it went away since the snapshot), and a volume envelope's
-- value as a linear gain.
local function ev(proj, e, pos)
  if not e or not reaper.ValidatePtr2(proj, e.env, "TrackEnvelope*") then return nil end
  local _, v = reaper.Envelope_Evaluate(e.env, pos, 0, 0)
  return v
end
local function evol(proj, e, pos)
  local v = ev(proj, e, pos)
  return v and reaper.ScaleFromEnvelopeMode(e.smode, v)
end
local function clamp(x) return math.max(-1, math.min(1, x)) end

-- The VCA leads of the groups a track follows (each counted once), with their volume envelopes:
-- a follower's output carries its leads' faders (measured: a lead at -6 dB, or at 0 dB with a
-- -12 dB envelope, moved its follower by just that, while the follower's own fader read 0 dB).
local function vca_gain(c, proj, st, pos, override)
  if st.follow[1] == 0 and st.follow[2] == 0 then return 1 end
  local g = 1
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local ls = track_cache(c, proj, tr)
    if (ls.lead[1] & st.follow[1]) ~= 0 or (ls.lead[2] & st.follow[2]) ~= 0 then
      local v = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
      if override ~= 6 then v = v * (evol(proj, ls.env["Volume"], pos) or 1) end
      g = g * v
    end
  end
  return g
end

-- A track's pan stage and volume as they play at pos (rfv_heard.lua's parameters). The API's
-- own D_VOL, D_PAN and D_WIDTH ignore automation (measured), so the envelopes are evaluated and
-- combined with them the way REAPER does in every automation mode (measured in trim/read, read,
-- touch, latch and write): Volume, Trim Volume and Volume (Pre-FX) multiply the fader, Pan adds
-- to the pan knob (pan envelopes are stored inverted: -1 = right), Width multiplies the width
-- knob, Pan (Pre-FX) is a balance stage of its own before the FX; VCA leads multiply in.
-- Override 6 bypasses all automation. -1 for mode or law is the project's default, which the
-- config variables hold for the active project (measured). Fader, pan and width are read every
-- frame, so a fader being dragged is followed at once.
local VOLUME_STAGES = { "Volume", "Trim Volume", "Volume (Pre-FX)" }
local function params(c, proj, tr, pos, defm, defl, override)
  local st = track_cache(c, proj, tr)
  local function v(k) return reaper.GetMediaTrackInfo_Value(tr, k) end
  local mode, law = st.mode, st.law
  if mode < 0 then mode = defm end
  if law < 0 then law = defl end
  local vol, pan, width, prepan = v("D_VOL"), v("D_PAN"), v("D_WIDTH"), 0
  if override ~= 6 then
    for _, name in ipairs(VOLUME_STAGES) do vol = vol * (evol(proj, st.env[name], pos) or 1) end
    pan = clamp(pan - (ev(proj, st.env["Pan"], pos) or 0))
    width = clamp(width * (ev(proj, st.env["Width"], pos) or 1))
    prepan = clamp(-(ev(proj, st.env["Pan (Pre-FX)"], pos) or 0))
  end
  vol = vol * vca_gain(c, proj, st, pos, override)
  return { mode = mode, pan = pan, width = width, dl = st.dl, dr = st.dr, law = law, vol = vol, prepan = prepan }
end

-- A track's pan matrix over [t0, t1) (a section, step 10b; step 9b review L5): where an envelope
-- or a VCA lead can move its volume, pan or width, the matrix at AVG_POINTS places across the
-- range, each entry the root of its squares' mean (the powers it passes on average; the sign of
-- the middle one), else the matrix at mid, as before. Exact for powers that do not correlate
-- left with right; the cross term is the middle one's.
local AVG_POINTS = 8
local AUTOMATED = { "Volume", "Trim Volume", "Volume (Pre-FX)", "Pan", "Width", "Pan (Pre-FX)" }
local function avg_matrices(list, mid)
  local out = {}
  for i = 1, 4 do
    local s = 0
    for _, M in ipairs(list) do s = s + M[i] * M[i] end
    local v = math.sqrt(s / #list)
    out[i] = (mid[i] < 0) and -v or v
  end
  return out
end
local function matrix_over(c, proj, tr, t0, t1, mid, defm, defl, override)
  local st = track_cache(c, proj, tr)
  local moves = override ~= 6 and (st.follow[1] ~= 0 or st.follow[2] ~= 0)
  if override ~= 6 and not moves then for _, name in ipairs(AUTOMATED) do if st.env[name] then moves = true; break end end end
  local Mmid = HD.matrix(params(c, proj, tr, mid, defm, defl, override))
  if not moves or t1 <= t0 then return Mmid end
  local list = {}
  for i = 1, AVG_POINTS do list[i] = HD.matrix(params(c, proj, tr, t0 + (i - 0.5) * (t1 - t0) / AVG_POINTS, defm, defl, override)) end
  return avg_matrices(list, Mmid)
end

-- A send as it plays at pos: volume and pan with their envelopes (combined like a track's,
-- measured: knob 0.5 with an envelope at 0.25 gave -12 dB more; pan knob +0.2 with an envelope
-- stored -0.5 gave +0.7), the mono switch, and whether it is muted (button or Send Mute at 0).
local function send_now(proj, tr, st, s, pos, override)
  local function sv(k) return reaper.GetTrackSendInfo_Value(tr, 0, s.i, k) end
  local vol, pan, muted = sv("D_VOL"), sv("D_PAN"), sv("B_MUTE") ~= 0
  local e = st.senv[s.i]
  if e and override ~= 6 then
    vol = vol * (evol(proj, e["Send Volume"], pos) or 1)
    pan = clamp(pan - (ev(proj, e["Send Pan"], pos) or 0))
    local m = ev(proj, e["Send Mute"], pos)
    if m and m < 0.5 then muted = true end
  end
  return HD.send_matrix(vol, pan, sv("B_MONO") ~= 0), muted
end
-- A send over [t0, t1) (a section, step 10b), as matrix_over: where it has envelopes, the matrix
-- at AVG_POINTS places (nothing where muted), muted only if muted at every one.
local function send_over(proj, tr, st, s, t0, t1, mid, override)
  local M, muted = send_now(proj, tr, st, s, mid, override)
  if override == 6 or not st.senv[s.i] or t1 <= t0 then return M, muted end
  local list, all = {}, true
  for i = 1, AVG_POINTS do
    local Mi, mi = send_now(proj, tr, st, s, t0 + (i - 0.5) * (t1 - t0) / AVG_POINTS, override)
    list[i] = mi and { 0, 0, 0, 0 } or Mi
    all = all and mi
  end
  if all then return M, true end
  return avg_matrices(list, M), false
end

local function color_of(tr)
  local c = reaper.GetTrackColor(tr)
  if c == 0 then return J.null end
  local r, g, b = reaper.ColorFromNative(c)
  return string.format("#%02X%02X%02X", r, g, b)
end

local function project_name(proj)
  local fn = S.project_file(proj)
  return fn, (fn ~= "" and fn:match("[^/\\]+$") or "(unsaved)")
end

-- Where what playing taught is kept for a project between runs (step 9a review, the owner's
-- choice): REAPER's resource folder, Data/ReaperForVisual/learned/<section>/, never beside the
-- project; the file named after the project and a hash of its full path. Returns the folder and
-- the file, or nil for an unsaved project (kept in memory only).
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return h
end
function E.learn_file(proj, section)
  local fn = S.project_file(proj)
  if fn == "" then return nil end
  -- the user's engine keeps it in memory only for a project in the system's temporary folder: the
  -- tests' fixtures, whose tabs it follows while a test runs (a test engine writes under its own
  -- section, which the test harness empties)
  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR")
  if (section or E.SECTION) == E.SECTION and tmp and tmp ~= ""
     and fn:lower():gsub("\\", "/"):sub(1, #tmp) == tmp:lower():gsub("\\", "/") then return nil end
  local sep = package.config:sub(1, 1)
  local base = (fn:match("[^/\\]+$") or "project"):gsub("%.[Rr][Pp][Pp]$", ""):gsub("[^%w%-_ ]", "_"):sub(1, 40)
  local dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "ReaperForVisual" .. sep .. "learned" .. sep .. (section or E.SECTION)
  return dir, dir .. sep .. ("%s-%08x.txt"):format(base, fnv1a(fn:lower()))
end

-- A track's FX chain as learning sees it (step 9a): a fingerprint (the chain switch and each FX on
-- or off, in order) and whether any FX acts.
local function fx_fp(tr)
  local on = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") ~= 0
  local parts, any = { on and "1" or "0" }, false
  for f = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local en = reaper.TrackFX_GetEnabled(tr, f)
    parts[#parts + 1] = en and "1" or "0"
    if en and on then any = true end
  end
  return table.concat(parts, ""), any
end

local function arr(list, f)
  local a = J.array{}
  for i, v in ipairs(list) do a[i] = f and f(v) or v end
  return a
end

-- The user's overrides as one string, to notice when they change.
local function opts_key(doc)
  if not doc then return "" end
  return J.encode(doc.roles or J.object{}) .. "|" .. J.encode(doc.paths or J.object{})
end

-- Look at the routing (~1.4 ms at 224 tracks). Classify again (~0.9 ms) only when the routing,
-- the user's overrides or the meter safety net changed. Returns true when the roles changed.
local function refresh_roles(proj, c, t)
  c.snap_t = t
  local t0 = now()
  local snap = SN.from_api(proj)
  c.snap_ms = 1000 * (now() - t0)
  local doc = c.st.doc
  local key = opts_key(doc)
  if c.res and not c.reclass and key == c.opts_key and SN.equal(snap, c.snap) then return false end
  t0 = now()
  c.snap, c.opts_key, c.reclass = snap, key, false
  c.res = RO.classify(snap, { roles = doc and doc.roles, paths = doc and doc.paths, heard = c.heard })
  c.roles_ms, c.classified = 1000 * (now() - t0), c.classified + 1
  -- the meter safety net listens to tracks that are silent by routing yet reach the master
  c.cand = {}
  for k, r in ipairs(c.res.tracks) do
    if r.role == "ignored" and r.kind ~= "unheard" and r.kind ~= "user" and r.reach then c.cand[#c.cand + 1] = k end
  end
  return true
end

-- Meter safety net: a candidate heard in NET_FRAMES frames is classified again as a source
-- ("unexplained"): a JS synth, a generator, an input that is not armed.
local function net_listen(proj, c)
  for _, k in ipairs(c.cand) do
    local tr = reaper.GetTrack(proj, k - 1)
    if tr and math.max(reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1)) > NET_PEAK then
      local guid = c.snap.tracks[k].guid
      if reaper.GetTrackGUID(tr) == guid and not c.heard[guid] then
        c.hits[guid] = (c.hits[guid] or 0) + 1
        if c.hits[guid] >= NET_FRAMES then c.heard[guid] = true; c.heard_n = c.heard_n + 1; c.reclass = true end
      end
    end
  end
end

-- A track the safety net took in, silent for NET_RELEASE seconds of playing, is let go: its role
-- is what the routing says again (step 10a). Called once a frame while playing; dt: the time
-- since the last call.
local function net_release(proj, c, dt)
  if c.heard_n == 0 or not c.snap then return end
  c.quiet = c.quiet or {}
  for k, sn in ipairs(c.snap.tracks) do
    local g = sn.guid
    if c.heard[g] then
      local tr = reaper.GetTrack(proj, k - 1)
      local loud = tr and math.max(reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1)) > NET_PEAK
      c.quiet[g] = loud and 0 or (c.quiet[g] or 0) + dt
      if c.quiet[g] >= NET_RELEASE then
        c.heard[g], c.hits[g], c.quiet[g] = nil, nil, nil
        c.heard_n, c.reclass = c.heard_n - 1, true
      end
    end
  end
end

-- Track colours as one string (~0.05 ms at 224 tracks): the one part of the graph that the
-- routing snapshot does not hold.
local function colors_of(proj)
  local t = {}
  for i = 0, reaper.CountTracks(proj) - 1 do t[i + 1] = reaper.GetTrackColor(reaper.GetTrack(proj, i)) end
  return table.concat(t, ",")
end

-- The tracks whose files the stage needs (step 7): each object's own track, then every track
-- that reaches one of them, on a main path or by a send, again and again. In stage order, so
-- the spectrum map serves the chosen tracks first. Then every other track (step 9a): stopped,
-- the whole mix comes from the files, and its level is what every part's Z is measured against.
-- Returns { { track, guid }, ... } and the set by index of those the stage needs.
local function y_need(c, proj, objs, n)
  local res, snap = c.res, c.snap
  if not res or not snap or #res.tracks ~= n then return {}, {} end
  local want, order = {}, {}
  local function add(k)
    if k and k >= 1 and k <= n and not want[k] then want[k] = true; order[#order + 1] = k; return true end
  end
  for _, o in ipairs(objs) do
    if o.kind == "group" then for _, k in ipairs(o.members or {}) do add(k) end else add(o.track) end
  end
  local grew = true
  while grew do
    grew = false
    for k = 1, n do
      if not want[k] then
        for _, b in ipairs(res.tracks[k].path or {}) do if want[b] then grew = add(k) or grew; break end end
      end
    end
    for _, s in ipairs(snap.sends or {}) do
      if s.dst > 0 and want[s.dst] and s.srcchan >= 0 and not want[s.src] then grew = add(s.src) or grew end
    end
  end
  local need = {}
  for _, k in ipairs(order) do
    local tr = reaper.GetTrack(proj, k - 1)
    if tr then need[#need + 1] = { tr, snap.tracks[k].guid } end
  end
  for k = 1, n do
    local tr = not want[k] and reaper.GetTrack(proj, k - 1)
    if tr then need[#need + 1] = { tr, snap.tracks[k].guid } end
  end
  return need, want
end

-- The structure of one tab as a graph document (without gseq) and its track count.
local function build_graph(proj, c)
  local tracks = J.array{}
  local n = reaper.CountTracks(proj)
  -- audio sends of each track (destinations), for choosing a main path on the page
  local sends_of = {}
  for _, sd in ipairs(c.snap and c.snap.sends or {}) do
    if sd.dst > 0 and sd.srcchan >= 0 and not sd.mute then
      local l = sends_of[sd.src] or {}
      local dup = false
      for _, d in ipairs(l) do if d == sd.dst then dup = true end end
      if not dup then l[#l + 1] = sd.dst end
      sends_of[sd.src] = l
    end
  end
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(proj, i)
    -- P_NAME is empty for an unnamed track; GetTrackName would say "Track 5", a label that
    -- changes when tracks move. The page shows "Track N" by the current position instead.
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local parent = reaper.GetParentTrack(tr)
    local o = J.object{
      i = i, guid = reaper.GetTrackGUID(tr), name = name, color = color_of(tr),
      parent = parent and reaper.GetTrackGUID(parent) or J.null,
      depth = reaper.GetTrackDepth(tr), folder = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1,
    }
    -- Roles count tracks from 1; the graph counts from 0 (i). -1 is the master.
    local r, sn = c.res and c.res.tracks[i + 1], c.snap and c.snap.tracks[i + 1]
    if r and sn and sn.guid == o.guid then
      o.role, o.kind, o.reason, o.level, o.members = r.role, r.kind, r.reason, r.level, r.members
      o.flags = arr(r.flags)
      o.group = r.group > 0 and r.group - 1 or J.null
      o.dry = r.dry == nil and J.null or (r.dry == 0 and -1 or r.dry - 1)
      o.path = arr(r.path, function(k) return k - 1 end)
      o.layer_of = r.layer_of and r.layer_of - 1 or J.null
      o.via = r.via or J.null
      o.was = r.user and r.was or J.null -- the routing's own answer under a role the user set
    end
    o.sends = arr(sends_of[i + 1] or {}, function(k) return k - 1 end)
    tracks[#tracks + 1] = o
  end
  local fn, name = project_name(proj)
  local st, doc = c.st, c.st.doc
  -- the stage: what is drawn, as rfv_view.lua resolves the user's choices (step 6)
  local stage_tracks = {}
  if c.res and c.snap and #c.res.tracks == n then
    for k = 1, n do
      local r = c.res.tracks[k]
      stage_tracks[k] = { guid = c.snap.tracks[k].guid, role = r.role, group = r.group, path = r.path }
    end
  end
  local objs, smode = V.stage(stage_tracks, doc)
  c.stage, c.stage_n = objs, n
  c.yneed, c.yset = y_need(c, proj, objs, n)
  local stage = J.array{}
  for _, ob in ipairs(objs) do
    stage[#stage + 1] = J.object{ kind = ob.kind, track = ob.track and ob.track - 1 or J.null,
                                  parent = ob.parent and ob.parent - 1 or J.null, open = ob.open or false,
                                  members = ob.members and arr(ob.members, function(k) return k - 1 end) or J.null,
                                  sum = ob.sum and arr(ob.sum, function(k) return k - 1 end) or J.null,
                                  name = ob.name or J.null, group = ob.gi and ob.gi - 1 or J.null }
  end
  local groups = J.array{}
  for _, grp in ipairs(doc and doc.groups or {}) do groups[#groups + 1] = J.object{ name = tostring(grp.name or ""), tracks = grp.tracks } end
  local missing = J.array{}
  if doc then
    for _, g in ipairs(S.missing(doc, proj)) do missing[#missing + 1] = J.object{ guid = g, label = (doc.labels and doc.labels[g]) or J.null } end
  end
  local cands = J.array{}
  if not doc and fn ~= "" and not st.error then
    for _, cd in ipairs(S.adoption_candidates(proj)) do cands[#cands + 1] = J.object{ path = cd.path, project = cd.project or J.null, tracks = cd.tracks } end
  end
  local g = J.object{
    v = 0, version = E.VERSION, tab = tostring(proj), project = fn, name = name, tracks = tracks,
    master = reaper.GetTrackGUID(reaper.GetMasterTrack(proj)),
    view = doc and J.object{ mode = doc.view.mode, tracks = doc.view.tracks, groups = groups,
                             roles = doc.roles or J.object{}, paths = doc.paths or J.object{},
                             sections = doc.sections or J.object{ source = "regions" } } or J.null,
    stage = J.object{ mode = smode, objects = stage },
    history = J.object{ undo = c.hist and #c.hist.undo or 0, redo = c.hist and #c.hist.redo or 0 },
    store = J.object{ error = st.error and J.object{ code = st.error.code, msg = st.error.msg or "" } or J.null,
                      kept_as = st.kept_as or J.null, recovered_from = st.recovered_from or J.null,
                      missing = missing, candidates = cands },
    roles = c.res and J.object{ mixbuses = arr(c.res.mixbuses, function(k) return k - 1 end), feeders = c.res.feeders, basis = c.res.basis,
                                classified = c.classified, classify_ms = c.roles_ms, snapshot_ms = c.snap_ms,
                                heard = c.heard_n } or J.null,
  }
  return g, n
end

local function percentile(sorted, p)
  if #sorted == 0 then return 0 end
  return sorted[math.max(1, math.min(#sorted, math.floor(#sorted * p + 0.5)))]
end

-- One engine instance. opts.open_browser (default true) opens the page on start, unless a
-- page is already open; opts.section (default "ReaperForVisual") names the ExtState section.
function E.run(opts)
  opts = opts or {}
  SEC = opts.section or E.SECTION
  if reaper.set_action_options then reaper.set_action_options(1 | 4) end
  math.randomseed(math.floor(now() * 1000) % 2147483647)
  local token = string.format("%.6f-%d", now(), math.random(1, 999999999))
  setx("owner", token)
  setx("command", "")
  -- a page command still waiting from before this start (sent while the engine was off, or
  -- the last one an earlier run applied) is not applied now: the page will report no answer
  setx("cmd", "")

  local T = {
    seq = 0, gseq = tonumber(getx("gseq_last")) or 0, tabs = {}, cur = nil, next_pub = 0, last_prune = now(),
    costs = {}, gaps = {}, cost_i = 0, cost = "{}", cost_t = 0, ticks = 0, errors = 0, last_error = nil, last_t0 = nil,
    -- step 10a: the frames' own cycles; the longest tick and the longest gap since the start, when
    -- (seconds since the start) and, for the tick, what it did (a 5.5-minute stall was once seen in
    -- a suite run, step 8 review, with nothing to say when)
    fcosts = {}, fcost_i = 0, kind = "", max_d = 0, max_at = 0, max_kind = "", max_gap = 0, max_gap_at = 0,
    jobs = {}, -- the learning files being written, a few keys a tick (step 10a)
    running = true, reason = "", started = now(),
    ack = 0, ack_ok = nil, ack_msg = nil, ping = nil, note_n = 0, note = nil,
    -- the light: the user's engine drives the real action's; a test engine none, or the one it names
    light = nil, light_id = math.type(opts.light) and opts.light or 0,
    kind_ms = {}, -- the last cycle of each kind, whole (frame, gather, finish): step 7's load figures
  }
  if opts.light == nil then T.light = SEC == E.SECTION else T.light = opts.light ~= false end
  if T.light and T.light_id == 0 then T.light_id = E.all_action_id() end

  -- The page's Undo and Redo (step 6 review, U1): every version of a tab's choices the engine
  -- sees, made by the page, an action or another program, in memory while it runs. A different
  -- document in the tab (another project, or choices found under a new name) starts afresh.
  local function remember(c, ev)
    local s = V.snapshot(c.st.doc)
    local h = c.hist
    if not h or ev == "other-project" or ev == "loaded-existing" then
      c.hist = { now = s, undo = {}, redo = {} }
    elseif s ~= h.now then
      h.undo[#h.undo + 1] = h.now
      if #h.undo > UNDO_MAX then table.remove(h.undo, 1) end
      h.redo, h.now = {}, s
    end
  end

  local function tab_cache(proj)
    local key = tostring(proj)
    local c = T.tabs[key]
    if not c then
      c = { proj = proj, st = {}, store_t = 0, sc = nil, graph_t = -1, json = nil, n = -1,
            snap = nil, res = nil, snap_t = -1, snap_ms = 0, roles_ms = 0, classified = 0, opts_key = nil, reclass = false,
            cand = {}, hits = {}, heard = {}, heard_n = 0,
            ms = {}, ms_n = -1, mst = MT.new_track(), decay = MT.new_decay(vudecay() * REFRESH, REFRESH), ts = {}, cache_t = -1e9 }
      T.tabs[key] = c
    end
    return c, key
  end

  local function publish_graph(g)
    T.gseq = T.gseq + 1
    g.gseq = T.gseq
    setx("graph", J.encode(g))
    setx("gseq_last", tostring(T.gseq))
  end

  -- Read every track's meter (and the master's) into its state: every tick, because the meter
  -- refreshes every ~46.7 ms and each refresh counts (engine/rfv_meter.lua).
  local function read_meters(proj, c, t)
    local n = reaper.CountTracks(proj)
    if n ~= c.ms_n then -- tracks added or removed: keep only the states of tracks still here
      local keep, keep_ts = {}, {}
      for i = 0, n - 1 do local tr = reaper.GetTrack(proj, i); keep[tr], keep_ts[tr] = c.ms[tr], c.ts[tr] end
      c.ms, c.ts, c.ms_n = keep, keep_ts, n
    end
    local d = c.decay
    d.playing = reaper.GetPlayStateEx(proj) & 1 == 1 -- the decay rate is measured while playing only
    for i = 0, n - 1 do
      local tr = reaper.GetTrack(proj, i)
      local s = c.ms[tr]
      if not s then s = MT.new_track(); c.ms[tr] = s end
      MT.feed(s, d, t, reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1))
    end
    local m = reaper.GetMasterTrack(proj)
    MT.feed(c.mst, d, t, reaper.Track_GetPeakInfo(m, 0), reaper.Track_GetPeakInfo(m, 1))
  end

  -- Heard X and Z: every track's own powers carried up its main path (rfv_heard.lua), with every
  -- volume and pan stage of its buses as they play now, and what mute and solo silence on the
  -- way (S: the frame's mute, solo and solo-defeat states). Needs the roles of the current
  -- structure.
  -- model (step 9a, stopped): own holds the tracks' outputs from their files; every bus's output
  -- is then worked out from its inputs, with the FX gains learned while playing (model.L, over
  -- [model.t0, model.t1)), and model.basis (the shares of each track's output learned here,
  -- elsewhere, never) is carried through.
  local function heard(proj, c, own, n, pos, tracks, defm, defl, override, S, rho, model)
    local res = c.res
    if not res or #res.tracks ~= n or not c.snap then return nil end
    local dry, via, way, bus, outm, hopmute, main = {}, {}, {}, {}, {}, {}, {}
    -- a section's stage (step 10b): every matrix over the section, automation averaged
    local avg = model and model.avg
    local function mat(k)
      if avg then return matrix_over(c, proj, tracks[k], model.t0, model.t1, pos, defm, defl, override) end
      return HD.matrix(params(c, proj, tracks[k], pos, defm, defl, override))
    end
    local function snd(tr, st, s)
      if avg then return send_over(proj, tr, st, s, model.t0, model.t1, pos, override) end
      return send_now(proj, tr, st, s, pos, override)
    end
    local function bus_of(d)
      local sn = c.snap.tracks[d]
      -- the FX gain only where it can be measured: not on a bus with a sound of its own (items,
      -- an instrument), nor on an armed one (its meter shows its input)
      return { M = mat(d),
               fx = sn.nfx > 0 and sn.fxon and not sn.audio and not sn.instr and not sn.arm }
    end
    for k = 1, n do
      local r = res.tracks[k]
      local d = r.dry
      dry[k], via[k] = d, r.via
      if d and d > 0 and not bus[d] then bus[d] = bus_of(d) end
      if d and d > 0 and r.via == "send" then -- the send that is its main path
        local st = track_cache(c, proj, tracks[k])
        for _, s in ipairs(st.sends) do
          if s.dst == d then
            local M, muted = snd(tracks[k], st, s)
            way[k], hopmute[k], main[k] = M, muted, s
            -- 1: before the FX; 2 and 3: after the FX, before the fader; 0: after the fader
            outm[k] = s.mode == 1 and 1 or (s.mode ~= 0 and 3 or 0)
            break
          end
        end
      end
    end
    -- A track fed only by sends (a return) is a bus too, for its FX gain (step 9a: learned
    -- while playing, used while stopped). It is on no one's main path, so heard values stay those
    -- of the main paths, and it is never flagged for an image gap (a reverb spreads by design).
    for _, s in ipairs(c.snap.sends) do
      local d = s.dst
      if d > 0 and d <= n and s.srcchan >= 0 and not bus[d] then bus[d] = bus_of(d); bus[d].ret = true end
    end
    local A = HD.audible(n, dry, via, S.solo, S.defeat, S.muted, hopmute)
    -- every other audio send into a bus counts in that bus's prediction
    if c.senders_t ~= c.snap_t then
      c.senders, c.senders_t = {}, c.snap_t
      for _, s in ipairs(c.snap.sends) do c.senders[s.src] = true end
    end
    local sides, tap, approx, ysides = {}, {}, {}, {}
    for k in pairs(c.senders) do
      local st = track_cache(c, proj, tracks[k])
      for _, s in ipairs(st.sends) do
        if s ~= main[k] and s.dst and s.dst > 0 and s.srcchan >= 0 and s.dstchan % 512 < 2 then
          local M, muted = snd(tracks[k], st, s)
          if not muted then
            local sd = { src = k, dst = s.dst, M = M, pre = s.mode ~= 0,
                         pass = not S.muted[k] and (not A.any or A.live[k] or A.under(s.dst)) }
            ysides[#ysides + 1] = sd -- the spectra hear every audio send, a return's too (step 7)
            if bus[s.dst] then -- the FX gain of a bus counts the sends into it
              sides[#sides + 1] = sd
              if s.mode ~= 0 then tap[k] = true end
            end
          end
        end
      end
    end
    -- a send taken before the fader starts from the track's output with its fader and pan undone
    -- (one taken before the FX too: the FX are ignored there, so heard values resting on it are
    -- approximate)
    local want_tap = {}
    for k = 1, n do want_tap[k] = tap[k] or (outm[k] or 0) ~= 0 end
    local function taps()
      for k = 1, n do
        if want_tap[k] and own[k] then
          tap[k] = { HD.untap(mat(k), own[k][1], own[k][2]) }
        else
          tap[k] = nil
        end
      end
    end
    taps()
    local master = reaper.GetMasterTrack(proj)
    bus[0] = { M = HD.matrix(params(c, proj, master, pos, defm, defl, override)),
               fx = reaper.TrackFX_GetCount(master) > 0 and reaper.GetMediaTrackInfo_Value(master, "I_FXEN") ~= 0 }
    local o = { silenced = A.silenced, pass = A.pass, tap = tap, outm = outm, sides = sides, rho = rho }
    local basis, gbasis
    if model then
      -- each bus's FX gain as learned here, elsewhere in the song, or not at all (then 1)
      local fixed = {}
      gbasis = {}
      for b, info in pairs(bus) do
        local key = b == 0 and "master" or c.snap.tracks[b].guid
        -- every FX on it switched off: nothing to learn, its gain is 1
        if info.fx and not (c.fxact and c.fxact[key] == false) then
          local g, here = LN.at(model.L, key .. ":g", model.t0, model.t1)
          fixed[b] = g and 10 ^ (g / 10) or 1
          -- the master's gain, and a mix bus's (the owner's premaster), is in every part and in the
          -- mix alike, so Z does not rest on it (step 9a review)
          if b > 0 and res.tracks[b].role ~= "mixbus" then gbasis[b] = g and { here, 1 - here, 0 } or { 0, 0, 1 } end
        end
      end
      -- model.meas: each bus's share its meters measured, carried in the same pass (step 9b review)
      o.gain, o.basis, o.gbasis, o.meas = fixed, model.basis, gbasis, model.meas
      own, basis = HD.fill(n, own, dry, way, bus, o)
      taps() -- sends taken before the fader of a bus just worked out
      bus[0].out = own[0]
    else
      local mx, mz = MT.estimate(c.mst, now(), c.decay)
      bus[0].out = mz and { HD.powers(mx, mz) } or nil
    end
    local h, gain, gap = HD.propagate(n, own, dry, way, bus, o)
    -- A live input that is the only input of its bus is heard exactly where the bus is: the
    -- bus's meter measures what the input's own meter cannot (it meters the input).
    local members = {}
    for k = 1, n do local d = dry[k]; if d and d > 0 then members[d] = (members[d] or 0) + 1 end end
    local via_bus = {}
    for k = 1, n do
      local d = dry[k]
      local sn = c.snap.tracks[k]
      if sn.arm and sn.recmon > 0 and d and d > 0 and members[d] == 1 and h[d] and not A.silenced[k] then h[k], via_bus[k] = h[d], true end
    end
    -- heard values that rest on a send taken before the FX, somewhere on the way
    for k = 1, n do
      local x, guard = k, 0
      while x and x > 0 and guard < 64 do
        if outm[x] == 1 then approx[k] = true; break end
        x, guard = dry[x], guard + 1
      end
    end
    -- a bus is flagged when its image gap lasts: smoothed with a time constant of ~1 s (from the
    -- meters only: a stage worked out, stopped or a section's, leaves the smoothing alone)
    local flagged = {}
    c.img = c.img or {}
    for b, info in pairs(model and {} or bus) do
      local g = not info.ret and gap[b]
      c.img[b] = g and (0.9 * (c.img[b] or g) + 0.1 * g) or nil
      if c.img[b] and c.img[b] > HD.IMAGE_DEG then flagged[b] = true end
    end
    -- the routing as read now, for the spectra (step 7); the FX gains (measured while playing,
    -- for learning) and, stopped, where each level comes from (step 9a)
    return h, flagged, via_bus, A, approx, { dry = dry, way = way, sides = ysides, bus = bus, gain = gain,
                                              basis = basis, gbasis = gbasis, own = own }
  end

  -- What playing taught a tab (step 9a), with its FX chains as last seen: read from the project's
  -- file in REAPER's resource folder when the tab is first seen; whenever the state counter moves,
  -- each track's chain is fingerprinted, and one that changed (an FX added, removed, switched on
  -- or off; whether playing or stopped: step 9a review) forgets what it learned. A track whose
  -- chain differs from the one the file knew starts afresh too.
  local function learning(c, proj, tracks, n)
    if not c.learn then c.learn = LN.new() end
    -- a track whose items changed (moved, muted, cut, ...) forgets the powers its meter measured:
    -- they were the old items' (the map fingerprints the items whenever the state counter moves)
    if c.ymap then
      c.ifp = c.ifp or {}
      for g, e in pairs(c.ymap.tracks) do
        local was = c.ifp[g]
        if e.fp and was ~= e.fp then
          if was then LN.forget(c.learn, g .. ":l"); LN.forget(c.learn, g .. ":r"); c.learn_dirty = true end
          c.ifp[g] = e.fp
        end
      end
    end
    local sc = reaper.GetProjectStateChangeCount(proj)
    if sc == c.fx_sc and c.fx_n == n then return c.learn end
    c.fx_sc, c.fx_n, c.fxfp, c.fxact = sc, n, c.fxfp or {}, {}
    for k = 0, n do
      local tr = k == 0 and reaper.GetMasterTrack(proj) or tracks[k]
      if tr and reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
        local key = k == 0 and "master" or c.snap.tracks[k].guid
        local fp, any = fx_fp(tr)
        if c.fxfp[key] and c.fxfp[key] ~= fp then LN.forget(c.learn, key .. ":"); c.learn_dirty = true end
        c.fxfp[key], c.fxact[key] = fp, any
      end
    end
    if not c.learn_read then
      c.learn_read = true
      local _, file = E.learn_file(proj, SEC)
      local f = file and io.open(file, "rb")
      local lt0 = now()
      if f then
        -- each key's blocks kept as text, parsed only for the keys taken (step 10a: parsed into
        -- tables first, the owner's 110 KB file took 42 ms, at the engine's start)
        local fps, ifps, t = {}, {}, {}
        for line in f:lines() do
          local tag = line:sub(1, 2)
          if tag == "k " then
            local k2, rest = line:match("^k (%S+) (.*)$")
            if k2 then t[k2] = rest end
          elseif tag == "fx" then
            local key, fp = line:match("^fx (%S+) (%S+)$")
            if key then fps[key] = fp end
          elseif tag == "it" then
            local ig, ih = line:match("^it (%S+) (%x+)$")
            if ig then ifps[ig] = ih end
          end
        end
        f:close()
        -- each track's items as they are now: the powers measured over other items are dropped
        local inow = {}
        for k = 1, n do
          local tr = tracks[k]
          if tr and reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
            local fp = YM.fingerprint(tr)
            local g = c.snap.tracks[k].guid
            inow[g] = ("%08x"):format(fnv1a(fp))
            c.ifp = c.ifp or {}
            c.ifp[g] = c.ifp[g] or fp
          end
        end
        local taken = 0
        for key, text in pairs(t) do
          local owner, kind = key:match("^(.-):([glr])$")
          local keep = owner and fps[owner] ~= nil and fps[owner] == c.fxfp[owner]
            and (kind == "g" or (ifps[owner] ~= nil and ifps[owner] == inow[owner]))
          if keep and LN.load_text(c.learn, key, text) then taken = taken + 1 end
        end
        c.learn_loaded = taken
        T.load_ms = 1000 * (now() - lt0) -- shown in the frame's "ym" (step 10a)
      end
    end
    return c.learn
  end

  -- Write what a tab learned to its project's file, when it changed: when playing stops and when
  -- the engine stops. Through a .tmp file, so a cut write leaves the last good one. When playing
  -- stops, a few keys at a time (at most SAVE_BUDGET seconds a tick), as a job the ticks go on
  -- with (step 10a: the owner's 110 KB took 34 ms at once); at the engine's stop (sync) in one go.
  -- T.save_ms is the work it took, not the time it spread over.
  local SAVE_BUDGET = 0.002
  local function save_learning(c, proj, sync)
    if not c.learn or not c.learn_dirty or not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end
    c.learn_dirty = false
    local dir, file = E.learn_file(proj, SEC)
    if not file then return end
    local job = coroutine.create(function(deadline)
      local work, t0 = 0, now()
      local function pause() -- yield once this tick's share is spent
        if now() >= deadline then
          work = work + (now() - t0)
          deadline = coroutine.yield()
          t0 = now()
        end
      end
      reaper.RecursiveCreateDirectory(dir, 0)
      local out = { "rfv-learn 1" }
      for key, fp in pairs(c.fxfp or {}) do out[#out + 1] = ("fx %s %s"):format(key, fp) end
      for g, fp in pairs(c.ifp or {}) do out[#out + 1] = ("it %s %08x"):format(g, fnv1a(fp)) end
      local keys = {} -- the keys as they are now: learning may add more meanwhile
      for key in pairs(c.learn.keys) do keys[#keys + 1] = key end
      for _, key in ipairs(keys) do
        pause()
        local text = LN.key_text(c.learn, key)
        if text then out[#out + 1] = ("k %s %s"):format(key, text) end
      end
      pause()
      local f = io.open(file .. ".tmp", "wb")
      if not f then return end
      local text = table.concat(out, "\n") .. "\n"
      f:write(text)
      f:close()
      os.remove(file)
      os.rename(file .. ".tmp", file)
      T.save_ms, T.save_kb = 1000 * (work + now() - t0), #text / 1024 -- shown in the frame's "ym"
    end)
    if sync then
      local ok = true
      while ok and coroutine.status(job) ~= "dead" do ok = coroutine.resume(job, math.huge) end
    else
      T.jobs[#T.jobs + 1] = job
    end
  end
  -- Go on with the jobs (the learning written a few keys at a time) for SAVE_BUDGET seconds.
  local function run_jobs()
    local job = T.jobs[1]
    if not job then return end
    local ok, err = coroutine.resume(job, now() + SAVE_BUDGET)
    if not ok then T.save_err = tostring(err) end -- shown in the frame's "ym" (step 10a review G2)
    if not ok or coroutine.status(job) == "dead" then table.remove(T.jobs, 1) end
  end
  -- Every job to its end at once (the engine stops).
  local function finish_jobs()
    while T.jobs[1] do
      local job = table.remove(T.jobs, 1)
      local ok = true
      while ok and coroutine.status(job) ~= "dead" do ok = coroutine.resume(job, math.huge) end
    end
  end

  -- Whether a track plays a MIDI item somewhere in [t0, t1) (a virtual instrument there).
  local function midi_at(tr, t0, t1)
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if p < t1 and p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") > t0 and reaper.GetMediaItemInfo_Value(it, "B_MUTE") == 0 then
        local tk = reaper.GetActiveTake(it)
        if tk and reaper.TakeIsMIDI(tk) then return true end
      end
    end
    return false
  end

  -- Stopped (step 9a, decision 1): the meters say nothing. Where the song played (half the next
  -- Y_SPAN seconds at least), each track stands where its meter put it then: the power it measured
  -- before its fader and pan, through its fader and pan as they are now (step 9a review F1: files
  -- read in short windows missed drum hits, 2 to 11 dB off what the meters heard on the owner's
  -- mix). Elsewhere its own output comes from its files at the edit cursor through its fader and
  -- pan as they are now, times its FX gain as learned (else 1: "FX not known"); a track without
  -- files (a virtual instrument) where it has MIDI, the median of the power it had (decision 3).
  -- A track armed with monitoring keeps its meter (decision 2), so dither and FX noise while
  -- stopped are never parts; a muted track is silent. Replaces own in place and returns the model
  -- for heard(): the learning, [t0, t1), each track's basis (the shares of its output known
  -- here, elsewhere, never) and how much of the files it rests on is read. A section's stage (step
  -- 9b) is the same over the section, with blend: what was measured in it for the blocks that
  -- played, the files for the others (step 9b review: the files over the whole section put a part
  -- that plays only where the user never listened into the share that played). A files' level is
  -- their power over every window read there, silence included (step 9b review: a part that plays
  -- in half a section is half as loud there on average).
  -- nolevel: the virtual instruments with MIDI there never heard (no level; the page says so).
  local function stage_model(c, proj, own, n, pos, tracks, defm, defl, override, S, t0, t1, blend, nolevel)
    local L = learning(c, proj, tracks, n)
    local map = c.ymap
    local basis = {}
    -- the shares of each output its meter measured there (basis counts a part with no FX as known
    -- exactly from its files; step 9b review: a section never played read "100 % measured", and
    -- the cursor "as measured here", on a project without FX)
    local meas = {}
    local touched = {} -- the share of the blocks read at least once, of each track whose level needs its files
    for k = 1, n do
      local sn = c.snap.tracks[k]
      if sn.arm and sn.recmon > 0 then
        if own[k] then basis[k], meas[k] = { 1, 0, 0 }, { 1, 0, 0 } end -- played live: its meter
      else
        own[k] = nil
        local e = map and map.tracks[sn.guid]
        if e and not S.muted[k] then
          local Mk -- its pan matrix, worked out only for a track with something to put through it
          local function M()
            Mk = Mk or (blend and matrix_over(c, proj, tracks[k], t0, t1, pos, defm, defl, override)
                        or HD.matrix(params(c, proj, tracks[k], pos, defm, defl, override)))
            return Mk
          end
          local set = blend and {} or nil
          local l, here = LN.here(L, sn.guid .. ":l", t0, t1, set)
          local r = LN.here(L, sn.guid .. ":r", t0, t1)
          local measured = l and r and { HD.through(M(), 10 ^ (l / 10), 10 ^ (r / 10)) } or nil
          if not measured then here, set = 0, nil end
          -- the files' (or a virtual instrument's median), where it did not play
          local fm, fb
          if not measured or (blend and here < 1) or (not blend and here < 0.5) then
            local s, _, _, wins
            s, _, _, wins, touched[k] = YM.stats(map, sn.guid, t0, t1, set)
            local fxon = c.fxact[sn.guid] -- any FX acting on it
            if s and wins > 0 and s[1] + s[2] > 0 then
              local o = SP.through(M(), s)
              local g, gh
              if fxon then g, gh = LN.at(L, sn.guid .. ":g", t0, t1) end
              local f = (g and 10 ^ (g / 10) or 1) / (wins * SP.SCALE)
              fm = { o[1] * f, o[2] * f }
              fb = not fxon and { 1, 0, 0 } or g and { gh, 1 - gh, 0 } or { 0, 0, 1 }
            elseif (e.midi or sn.instr) and midi_at(tracks[k], t0, t1) then
              local ml, mh = LN.at(L, sn.guid .. ":l", t0, t1)
              local mr = LN.at(L, sn.guid .. ":r", t0, t1)
              if ml and mr then
                fm = { HD.through(M(), 10 ^ (ml / 10), 10 ^ (mr / 10)) }
                fb = { mh, 1 - mh, 0 }
              elseif not measured then
                nolevel[k] = true
              end
            elseif blend and measured and wins > 0 then -- read there, and silent
              fm, fb = { 0, 0 }, { 1, 0, 0 }
            end
          end
          if measured and not fm then -- played there (or the files say nothing there yet)
            own[k], basis[k], meas[k] = measured, { here, 1 - here, 0 }, { here, 1 - here, 0 }
          elseif measured and blend then
            -- the blocks that played as measured, the others the files'; where its level comes
            -- from, by power (the page's "measured" share is by power)
            local pm, pf = here * (measured[1] + measured[2]), (1 - here) * (fm[1] + fm[2])
            own[k] = { here * measured[1] + (1 - here) * fm[1], here * measured[2] + (1 - here) * fm[2] }
            local a = pm + pf > 0 and pm / (pm + pf) or here
            basis[k], meas[k] = { a + (1 - a) * fb[1], (1 - a) * fb[2], (1 - a) * fb[3] }, { a, 1 - a, 0 }
          elseif fm then -- less than half of it played: the files'
            own[k], basis[k], meas[k] = fm, fb, { 0, 1, 0 }
          end
        end
      end
    end
    return { L = L, t0 = t0, t1 = t1, basis = basis, meas = meas, touched = touched, avg = blend }
  end

  -- Playing (step 9a): learn what the stage needs once it stops. Every track's power as its meter
  -- measures it, before its fader and pan, over the meters' last Y_SPAN seconds; a track with
  -- active FX, also its FX gain: that power over what its files predict (when at least half of
  -- them is read), for the places that never played; a bus's FX gain, heard()'s (its meter over
  -- its inputs), not while anything is soloed (its meter then holds only what passes). The engine
  -- calls this only after Y_SPAN + 0.5 s of playing on: after a jump the meters still hold what
  -- played before it. A track whose FX chain changes forgets everything it learned; one whose
  -- items change, the powers its meter measured.
  local function learn(c, proj, yi)
    local L, map, n = learning(c, proj, yi.tracks, yi.n), c.ymap, yi.n
    local t0, t1 = yi.pos - Y_SPAN, yi.pos
    c.learn_dirty = true
    for k = 1, n do
      local sn = c.snap.tracks[k]
      local p = yi.own[k]
      local e = map and map.tracks[sn.guid]
      if p and p[1] + p[2] > 0 and e and not sn.arm and not yi.R.bus[k] and reaper.ValidatePtr2(proj, yi.tracks[k], "MediaTrack*") then
        local M = HD.matrix(params(c, proj, yi.tracks[k], yi.pos, yi.defm, yi.defl, yi.override))
        local ul, ur = HD.untap(M, p[1], p[2])
        if ul > 0 and ur > 0 then
          LN.add(L, sn.guid .. ":l", t0, t1, 10 * math.log(ul, 10))
          LN.add(L, sn.guid .. ":r", t0, t1, 10 * math.log(ur, 10))
        end
        if c.fxact[sn.guid] then
          -- over every window read, silence included, as the meter's 2 s
          local s, cover, _, wins = YM.stats(map, sn.guid, t0, t1)
          if s and s[1] + s[2] > 0 and cover >= 0.5 then
            local o = SP.through(M, s)
            local m = (o[1] + o[2]) / (wins * SP.SCALE)
            if m > 0 then LN.add(L, sn.guid .. ":g", t0, t1, 10 * math.log((p[1] + p[2]) / m, 10)) end
          end
        end
      end
    end
    if not (yi.A and yi.A.any) then
      for b, info in pairs(yi.R.bus) do
        local g = yi.R.gain and yi.R.gain[b]
        if info.fx and g and g > 0 then
          LN.add(L, (b == 0 and "master" or c.snap.tracks[b].guid) .. ":g", t0, t1, 10 * math.log(g, 10))
        end
      end
    end
  end

  -- A command from the page (step 6): ExtState "cmd" = "<seq>|<length>|<json>". The web
  -- interface cuts a request longer than ~1 KB without saying so (measured), so the length is
  -- checked; seq (the page's clock in ms) makes a resend harmless. The result goes back in the
  -- frame ("ack", "ack_ok", "ack_msg"). Every change goes through the store, like the actions.
  local function run_command(proj, c, raw)
    local seq, len, body = raw:match("^(%d+)|(%d+)|(.*)$")
    seq = tonumber(seq)
    if not seq or seq <= T.ack then return end
    local function done(ok, msg) T.ack, T.ack_ok, T.ack_msg = seq, ok, msg end
    if #body ~= tonumber(len) then
      return done(false, ("the command was cut short on the way (%d of %s bytes); nothing changed"):format(#body, len))
    end
    local okd, cmd = pcall(J.decode, body)
    if not okd or type(cmd) ~= "table" or type(cmd.op) ~= "string" then return done(false, "command not understood; nothing changed") end
    if cmd.tab ~= nil and cmd.tab ~= tostring(proj) then return done(false, "another project tab is active now; nothing changed") end
    local function val(x) if J.is_null(x) then return nil end return x end
    -- tracks: by GUID ("g"), or by graph index ("k", 0-based) with the graph version they were
    -- read from ("gseq"), which keeps a command of 150 tracks under the web interface's ~1 KB
    local guids = {}
    for _, g in ipairs(type(cmd.g) == "table" and cmd.g or {}) do guids[#guids + 1] = tostring(g) end
    if type(cmd.k) == "table" then
      if cmd.gseq ~= T.gseq then return done(false, "the tracks changed while the command was on its way; nothing changed (sent again)") end
      for _, k in ipairs(cmd.k) do
        local tr = math.type(k) and reaper.GetTrack(proj, math.floor(k))
        if not tr then return done(false, "no such track; nothing changed") end
        guids[#guids + 1] = reaper.GetTrackGUID(tr)
      end
    end
    local function count(n) return ("%d track%s"):format(n, n == 1 and "" or "s") end
    local said, bad
    local function edit(fn)
      local ok, err = S.edit(proj, c.st, fn)
      if ok then c.store_dirty = true end
      return ok, err
    end
    local op, ok, err = cmd.op, nil, nil
    if op == "take" then -- the tracks selected in REAPER
      local sel, names = AC.selected(proj)
      if #sel == 0 then return done(false, "no track is selected in REAPER; nothing changed") end
      if cmd.how == "add" then ok, err = edit(function(doc) V.add(doc, sel) end); said = "added " .. count(#sel) .. " selected in REAPER"
      elseif cmd.how == "group" then
        ok, err = edit(function(doc) said = ("grouped the %s selected in REAPER as \"%s\""):format(count(#sel), V.group(doc, sel, names) or "?") end)
      else ok, err = edit(function(doc) V.show(doc, sel) end); said = "shows the " .. count(#sel) .. " selected in REAPER" end
    elseif op == "show" or op == "add" or op == "remove" or op == "forget" then
      ok, err = edit(function(doc) V[op](doc, guids) end)
      said = ({ show = "shows ", add = "added ", remove = "removed ", forget = "forgot " })[op] .. count(#guids)
    elseif op == "group" then
      if #guids == 0 then return done(false, "no tracks to group; nothing changed") end
      local names, by = {}, {}
      for i = 0, reaper.CountTracks(proj) - 1 do
        local tr = reaper.GetTrack(proj, i)
        local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        by[reaper.GetTrackGUID(tr)] = nm
      end
      for i, g in ipairs(guids) do names[i] = by[g:upper()] or "" end
      ok, err = edit(function(doc) said = ("grouped %s as \"%s\""):format(count(#guids), V.group(doc, guids, names) or "?") end)
    elseif op == "ungroup" or op == "rename" then
      local i = tonumber(cmd.i)
      local n = c.st.doc and c.st.doc.groups and #c.st.doc.groups or 0
      if not i or i < 0 or i >= n then return done(false, "no such group; nothing changed") end
      if op == "ungroup" then ok, err = edit(function(doc) V.ungroup(doc, i + 1) end); said = "removed the group (its tracks stay shown)"
      else
        local nm = tostring(val(cmd.name) or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if nm == "" then return done(false, "a group needs a name; nothing changed") end
        ok, err = edit(function(doc) V.rename(doc, i + 1, nm) end); said = ("renamed the group \"%s\""):format(nm)
      end
    elseif op == "mode" then
      if cmd.m ~= "all" and cmd.m ~= "chosen" and cmd.m ~= "toggle" then return done(false, "unknown view mode; nothing changed") end
      ok, err = edit(function(doc) V.mode(doc, cmd.m); said = doc.view.mode == "all" and "shows the whole mix" or "shows the chosen tracks" end)
    elseif op == "sections" then
      if not SC.SOURCES[cmd.source or ""] then return done(false, "unknown source of sections; nothing changed") end
      ok, err = edit(function(doc)
        doc.sections = type(doc.sections) == "table" and doc.sections or J.object{}
        doc.sections.source = cmd.source
      end)
      said = ({ regions = "sections from regions", ["markers#"] = "sections from # markers", markers = "sections from every marker", off = "no sections" })[cmd.source]
    elseif op == "role" then
      local r = val(cmd.r)
      if not guids[1] and not cmd.g then return done(false, "no track named; nothing changed") end
      local g = type(cmd.g) == "string" and cmd.g or guids[1]
      if r ~= nil and not (V.ROLES[r] or tostring(r):match("^layer:{[%x%-]+}$")) then return done(false, "unknown role; nothing changed") end
      ok, err = edit(function(doc) V.role(doc, g, r) end)
      said = r and ("role set to " .. r) or "role back to what the routing says"
    elseif op == "path" then
      local g = type(cmd.g) == "string" and cmd.g or guids[1]
      if not g then return done(false, "no track named; nothing changed") end
      local d = val(cmd.d)
      ok, err = edit(function(doc) V.path(doc, g, d) end)
      said = d and "main path chosen" or "main path back to what the routing says"
    elseif op == "adopt" then
      local path, found = tostring(cmd.path or ""), false
      for _, cd in ipairs(S.adoption_candidates(proj)) do if cd.path == path then found = true end end
      local src = found and S.read(path)
      if not src then return done(false, "that file is not offered for this project; nothing changed") end
      ok, err = edit(function(doc)
        for _, key in ipairs({ "view", "groups", "roles", "paths", "sections" }) do doc[key] = src[key] end
      end)
      said = "took the choices from " .. path:match("[^/\\]+$")
    elseif op == "undo" or op == "redo" then
      local ev = S.follow(proj, c.st) -- first take in a change made a moment ago elsewhere
      if ev ~= "same" or not c.hist then remember(c, ev) end
      local h = c.hist
      local from, to = h[op], h[op == "undo" and "redo" or "undo"]
      if #from == 0 then return done(false, op == "undo" and "nothing to undo" or "nothing to redo") end
      local text = from[#from]
      ok, err = edit(function(doc) V.restore(doc, text) end)
      if ok then
        from[#from] = nil
        to[#to + 1] = h.now
        h.now = V.snapshot(c.st.doc)
      end
      said = op == "undo" and "undone (back as before the last change)" or "redone (the undone change is back)"
    else
      bad = true
    end
    if bad then return done(false, "unknown command; nothing changed") end
    done(ok, ok and ("view " .. said) or ("nothing changed: " .. tostring(err and (err.msg or err.code))))
  end

  -- Y and width (step 7): each needed track's files over the last Y_SPAN seconds (the next ones
  -- while stopped), through its pan matrix, buses adding up what their inputs bring by the power
  -- each measures, from what the last frame read (c.yin). Per track and per stage object
  -- [Y Hz, correlation, share of the power with no Y, share that passed FX we cannot hear, share
  -- of the window read so far (a bus or a return: of what its inputs bring, by power)]. About
  -- five times a second, in two cycles without a frame: at 224
  -- tracks the whole took ~1.5-1.8 ms (step 7 load test: reading the blocks 0.5-0.6, matrices
  -- 0.2, adding up 0.3-0.5, writing 0.3), so the blocks and matrices are gathered on one cycle and
  -- added up and written on the next.
  local function spectra_gather(c, proj)
    local yi = c.yin
    if not yi or not c.ymap or not c.yset or not c.snap or #c.snap.tracks ~= yi.n then return end
    local n, own, R, tracks, pos = yi.n, yi.own, yi.R, yi.tracks, yi.pos
    local playing = yi.play & 1 == 1
    local ya, yb = playing and pos - Y_SPAN or pos, playing and pos or pos + Y_SPAN
    local src, Mx, P, fx, cover, blind = {}, {}, {}, {}, {}, {}
    for k = 1, n do
      local sn = c.snap.tracks[k]
      if c.yset[k] then
        local e
        src[k], cover[k], e = YM.stats(c.ymap, sn.guid, ya, yb)
        blind[k] = e and e.midi
      end
      fx[k] = sn.nfx > 0 and sn.fxon
      -- the power each track brings: measured while playing; stopped, the model's (step 9a: a
      -- virtual instrument then has the power it had, so a group's unknown share holds); else
      -- its files' own power after its matrix
      if own[k] then P[k] = own[k][1] + own[k][2] elseif playing then P[k] = 0 end
      if R.bus[k] then Mx[k] = R.bus[k].M
      elseif src[k] and reaper.ValidatePtr2(proj, tracks[k], "MediaTrack*") then
        Mx[k] = HD.matrix(params(c, proj, tracks[k], pos, yi.defm, yi.defl, yi.override))
      end
    end
    c.yjob = { yi = yi, src = src, Mx = Mx, P = P, fx = fx, cover = cover, blind = blind, playing = playing, stage = c.stage, set = c.yset }
    if playing and yi.steady then learn(c, proj, yi) end
  end

  -- One tuple of Y and width: [Y Hz, correlation, share with no Y, share past unseen FX, share read].
  local function ytuple(s, uu, ff, cv)
    local y, cr = s and SP.y(s), s and SP.corr(s)
    if y and cr then return string.format("[%.0f,%.3f,%.2f,%.2f,%.2f]", y, cr, uu or 1, ff or 0, cv or 1) end
    return string.format("[null,null,%.2f,%.2f,%.2f]", uu or 1, ff or 0, cv or 1)
  end

  -- Y and width per stage object: a track, a bus or a return its own; a display group, or a bus
  -- carrying returns (sum), its tracks' by the power each brings (heard, else its files').
  local function object_tuples(c, Sy, u, f, r, h, by_heard)
    local oy = {}
    for _, ob in ipairs(c.stage) do
      local list = ob.sum or (ob.kind == "group" and ob.members)
      if list then
        local parts = {}
        for _, k in ipairs(list) do
          local p = h and h[k]
          local w = by_heard and (p and p[1] + p[2] or 0) or (Sy[k] and SP.power(Sy[k]) or 0)
          parts[#parts + 1] = { S = Sy[k], u = u[k], f = f[k], r = r[k], w = w }
        end
        local sc, uu, ff, rr = SP.combine(parts)
        oy[#oy + 1] = ytuple(sc, uu, ff, 1 - rr)
      else
        oy[#oy + 1] = ytuple(Sy[ob.track], u[ob.track], f[ob.track], 1 - r[ob.track])
      end
    end
    return oy
  end

  local function spectra_finish(c, proj)
    local j = c.yjob
    c.yjob = nil
    if not j or j.stage ~= c.stage or j.set ~= c.yset then return end -- the stage changed in between
    local yi = j.yi
    local n, h, A, R = yi.n, yi.h, yi.A, yi.R
    local cover, playing = j.cover, j.playing
    -- r: the share still to read, through the routing (a bus or a return reads nothing itself)
    local Sy, u, f, r = SP.compose(n, j.src, j.Mx, j.P, j.fx, R.dry, R.way, A and A.pass, R.sides, j.blind, cover)
    local tuple = ytuple
    local ycol, oy, rho = {}, {}, {}
    for k = 1, n do
      if Sy[k] then rho[k] = SP.corr(Sy[k]) end
      -- nothing to say (no files, no inputs, no sound): null, as for a track not needed
      ycol[k] = c.yset[k] and (Sy[k] or u[k] > 0) and tuple(Sy[k], u[k], f[k], 1 - r[k]) or "null"
    end
    c.yrho = rho
    if c.stage and c.stage_n == n then oy = object_tuples(c, Sy, u, f, r, h, playing) end
    local cv, cn = 0, 0
    for k in pairs(c.yset) do cv, cn = cv + (cover[k] or 1), cn + 1 end
    local dense, coarse = YM.progress(c.ymap, c.yneed, reaper.GetProjectLength(proj))
    local _, learned = LN.size(c.learn or LN.new())
    c.yout = { n = n, stage = c.stage, y = table.concat(ycol, ","), oy = table.concat(oy, ","),
      ym = string.format('{"tracks":%d,"now":%.2f,"song":%.2f,"coarse":%.2f,"learned":%d,"save_ms":%.1f,"save_kb":%.0f,"load_ms":%.1f,"save_err":%s,"ms":%.2f,"windows":%d,"wps":%.0f,"resets":%d,"reset_last":%s,"cycle_ms":{"frame":%.2f,"gather":%.2f,"finish":%.2f,"section":%.2f}}',
        cn, cn > 0 and cv / cn or 1, dense, coarse, learned, T.save_ms or 0, T.save_kb or 0, T.load_ms or 0, T.save_err and J.encode(T.save_err) or "null", c.ymap.ms, c.ymap.windows, c.ymap.wps or 0,
        c.ymap.resets or 0, c.ymap.reset_last and J.encode(c.ymap.reset_last) or "null",
        T.kind_ms.frame or 0, T.kind_ms.gather or 0, T.kind_ms.finish or 0, T.kind_ms.section or 0) }
  end

  -- One section's average stage (step 9b): the stage model over the whole section, blended (what
  -- the meters measured in it for the share of it that played, the files for the rest), with the
  -- faders, pans and buses as they are at its middle and mute and solo as they are now; its
  -- objects' [X, Z], Y and width, where each level comes from, the mix, and the share of its power
  -- measured there. yi: the last frame's routing (c.yin).
  local function section_stage(c, proj, sec, yi)
    local n, tracks = yi.n, yi.tracks
    for k = 1, n do if not reaper.ValidatePtr2(proj, tracks[k], "MediaTrack*") then return nil end end
    local own, nolevel = {}, {}
    local mid = (sec.a + sec.b) / 2
    local model = stage_model(c, proj, own, n, mid, tracks, yi.defm, yi.defl, yi.override, yi.S, sec.a, sec.b, true, nolevel)
    local h, _, _, A, _, R = heard(proj, c, own, n, mid, tracks, yi.defm, yi.defl, yi.override, yi.S, c.yrho, model)
    if not h or not R then return nil end
    local hp = {}
    for k = 1, n do local p = h[k]; if p and p[1] + p[2] > 0 then hp[k] = p end end
    local hbs = R.basis and HD.carry_basis(n, R.basis, R.dry, R.gbasis) or {}
    local hms = HD.carry_basis(n, model.meas or {}, R.dry, R.gbasis) -- measured there, as heard
    local o, ob, nl = {}, {}, {}
    local wsum, here = 0, 0
    for j, obj in ipairs(c.stage) do
      local p = V.object_powers(obj, hp)
      o[j] = p and axes_json(HD.azimuth(p[1], p[2]), 10 * math.log(p[1] + p[2], 10)) or "null"
      local w, v, mw = 0, { 0, 0, 0 }, 0
      for _, k in ipairs(obj.sum or (obj.kind == "group" and obj.members) or { obj.track }) do
        local q, b = hp[k], hbs[k]
        if q and b then
          local x = q[1] + q[2]
          w = w + x
          for i = 1, 3 do v[i] = v[i] + b[i] * x end
          mw = mw + (hms[k] and hms[k][1] or 0) * x
        end
      end
      ob[j] = w > 0 and string.format("[%.2f,%.2f,%.2f]", v[1] / w, v[2] / w, v[3] / w) or "null"
      if w > 0 and not obj.open then wsum, here = wsum + w, here + mw end
      if obj.track and nolevel[obj.track] and not hp[obj.track] then nl[#nl + 1] = tostring(j - 1) end
    end
    -- Y and width over the section; read enough once its windows read are as many as a 2 s
    -- readout's (step 9b review: as a share of a long section, every label read "reading" for
    -- the quarter of an hour the owner's song takes to read through)
    -- How much of the files the section's stage rests on is read (at least a window in a block):
    -- every track its Y and width need over the whole section, and every other track whose level
    -- needs its files, each as one (step 9b review: weighed by the share of the level from files,
    -- Verse 1 of OGW, 98 % measured, read 0 % where every height still rested on unread files)
    local tch = model.touched
    local src, Mx, P, fx, cover, blind = {}, {}, {}, {}, {}, {}
    for k = 1, n do
      local sn = c.snap.tracks[k]
      if c.yset[k] then
        local e, _
        src[k], cover[k], e, _, tch[k] = YM.stats(c.ymap, sn.guid, sec.a, sec.b)
        cover[k] = math.min(1, cover[k] * (sec.b - sec.a) / Y_SPAN)
        blind[k] = e and e.midi
      end
      fx[k] = sn.nfx > 0 and sn.fxon
      if own[k] then P[k] = own[k][1] + own[k][2] end
      if R.bus[k] then Mx[k] = R.bus[k].M
      elseif src[k] then Mx[k] = HD.matrix(params(c, proj, tracks[k], mid, yi.defm, yi.defl, yi.override)) end
    end
    local Sy, u, f, r = SP.compose(n, src, Mx, P, fx, R.dry, R.way, A and A.pass, R.sides, blind, cover)
    local oy = object_tuples(c, Sy, u, f, r, h, true)
    local rn, rs = 0, 0
    for _, x in pairs(tch) do rn, rs = rn + 1, rs + x end
    local m = own[0]
    return { o = table.concat(o, ","), oy = table.concat(oy, ","), ob = table.concat(ob, ","), nl = table.concat(nl, ","),
             ma = m and m[1] + m[2] > 0 and axes_json(HD.azimuth(m[1], m[2]), 10 * math.log(m[1] + m[2], 10)) or "null",
             played = wsum > 0 and here / wsum or 0, read = rn > 0 and rs / rn or 1 }
  end

  -- The song's sections (step 9b, ExtState "sections"): the list again whenever the state counter
  -- moves (a marker or a region added, moved, renamed), the choice in .rfv.json changes, or every
  -- 2 s; while a page is open, one section's average stage on a tick with nothing else to do, the
  -- sections in turn; published once a second with the graph version its objects follow. The
  -- section a page shows goes first whenever its stage is a second old, and is published at once
  -- (step 9b review: in turn, with twelve sections, it followed a fader 6 s late).
  local function sections_tick(c, proj, t)
    local doc = c.st and c.st.doc
    local src = doc and doc.sections and doc.sections.source or "regions"
    local sc = reaper.GetProjectStateChangeCount(proj)
    if sc ~= c.sect_sc or src ~= c.sect_src or t - (c.sect_t or 0) >= 2 then
      c.sect_sc, c.sect_src, c.sect_t = sc, src, t
      local list, used = SC.build(SC.read(proj), src, reaper.GetProjectLength(proj))
      local sig = { used }
      for _, x in ipairs(list) do sig[#sig + 1] = ("%s|%.3f|%.3f"):format(x.name, x.a, x.b) end
      sig = table.concat(sig, "\n")
      if sig ~= c.sect_sig then c.sect_sig, c.sect_list, c.sect_used, c.sect_out, c.sect_i = sig, list, used, {}, 0 end
    end
    local list = c.sect_list
    if not list then return end
    local yi = c.yin
    if #list > 0 and yi and c.stage and c.stage_n == yi.n and c.snap and #c.snap.tracks == yi.n and c.ymap and c.yset
       and t - (c.sect_w or 0) >= SECT_EVERY and E.page_recent(SEC) then
      c.sect_w = t
      local i = E.page_section(list, SEC)
      local seen = i and c.sect_out[i]
      if i and seen and seen.gseq == T.gseq and t - seen.t < 1 then i = nil end -- fresh: the next in turn
      if not i then
        c.sect_i = (c.sect_i or 0) % #list + 1
        i = c.sect_i
      else
        c.sect_pub = nil -- the one shown: out at once
      end
      local st = section_stage(c, proj, list[i], yi)
      if st then st.gseq, st.t = T.gseq, t; c.sect_out[i] = st end
    end
    if t - (c.sect_pub or -1) >= 1 then
      c.sect_pub = t
      local items = {}
      for i, x in ipairs(list) do
        local st = c.sect_out[i]
        if st and st.gseq == T.gseq then
          items[i] = string.format('{"name":%s,"a":%.3f,"b":%.3f,"played":%.2f,"read":%.2f,"ma":%s,"o":[%s],"oy":[%s],"ob":[%s],"nl":[%s]}',
            J.encode(x.name), x.a, x.b, st.played, st.read, st.ma, st.o, st.oy, st.ob, st.nl)
        else
          items[i] = string.format('{"name":%s,"a":%.3f,"b":%.3f}', J.encode(x.name), x.a, x.b)
        end
      end
      setx("sections", string.format('{"gseq":%d,"tab":%s,"source":%s,"used":%s,"list":[%s]}', T.gseq, J.encode(tostring(proj)),
        J.encode(c.sect_src), J.encode(c.sect_used or "off"), table.concat(items, ",")))
    end
  end

  -- Stopped (step 10a), what the stage at the edit cursor rests on, read cheaply each frame: the
  -- cursor, the state counter, the graph and the stage, the pan defaults, the files read around the
  -- cursor and the map's drops, every track's fader, pan and width and the master's, every mute,
  -- solo and solo defeat. A fader, a pan, a mute or a solo set by a script or a control surface
  -- does not move the state counter (measured), so they are read themselves (224 tracks' fader and
  -- pan: 0.08 ms).
  local function stopped_key(c, proj, tracks, n, pos, S, defm, defl, override)
    local near, resets = YM.read_near(c.ymap, pos, pos + Y_SPAN)
    local key = { pos = pos, n = n, gseq = T.gseq, stage = c.stage, sc = reaper.GetProjectStateChangeCount(proj),
                  defm = defm, defl = defl, ov = override, near = near, resets = resets, v = {} }
    local v = key.v
    local m = reaper.GetMasterTrack(proj)
    v[1], v[2] = reaper.GetMediaTrackInfo_Value(m, "D_VOL"), reaper.GetMediaTrackInfo_Value(m, "D_PAN")
    for k = 1, n do
      local tr, j = tracks[k], 4 * k
      v[j - 1] = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
      v[j] = reaper.GetMediaTrackInfo_Value(tr, "D_PAN")
      v[j + 1] = reaper.GetMediaTrackInfo_Value(tr, "D_WIDTH")
      v[j + 2] = (S.muted[k] and 1 or 0) + 2 * S.solo[k] + (S.defeat[k] and 8 or 0)
    end
    return key
  end
  local KEY_FIELDS = { "pos", "n", "gseq", "stage", "sc", "defm", "defl", "ov" }
  -- true when equal; else false and what differs (the frame counts both). The files read further
  -- around the cursor count only every NEAR_REFRESH seconds: at 224 tracks they read on for over
  -- a minute after a start, and each window read made the stage worked out again (step 10a).
  local NEAR_REFRESH = 0.3
  local function same_key(a, b, age)
    if not (a and b) then return false, "none" end
    for _, f in ipairs(KEY_FIELDS) do if a[f] ~= b[f] then return false, f end end
    local x, y = a.v, b.v
    if #x ~= #y then return false, "v" end
    for i = 1, #x do if x[i] ~= y[i] then return false, "v" end end
    if (a.near ~= b.near or a.resets ~= b.resets) and age >= NEAR_REFRESH then return false, "near" end
    return true
  end

  local function frame(state)
    local c = T.cur
    local proj = c and c.proj
    local ax, hx, hi, ae, hb, hm, ha, obs, mu, oc, ob, nl = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    local ycol, oy, ym = "", "", "null"
    local play, pos, solo, sm = 0, 0, 0, 0
    local ma, md, mp = "null", "null", "null"
    if proj and reaper.ValidatePtr2(0, proj, "ReaProject*") then
      local t = now()
      play = reaper.GetPlayStateEx(proj)
      pos = (play & 1 == 1) and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
      -- how long it has played on without a jump (step 9a: learning waits for the meters' window);
      -- when it stops, what was learned goes to the project's file
      if play & 1 == 1 then
        local rate = reaper.Master_GetPlayRate(proj)
        if not (c.lp_pos and math.abs((pos - c.lp_pos) - (t - c.lp_t) * rate) < 0.25) then c.play_from = t end
        c.lp_pos, c.lp_t, c.was_playing = pos, t, true
      else
        c.lp_pos, c.play_from = nil, nil
        if c.was_playing then c.was_playing = false; save_learning(c, proj) end
      end
      local n = reaper.CountTracks(proj)
      local defm, defl = 3, 1
      local ok1, pm = reaper.get_config_var_string("panmode")
      local ok2, pl = reaper.get_config_var_string("panlaw")
      if ok1 and tonumber(pm) then defm = tonumber(pm) end
      if ok2 and tonumber(pl) then defl = tonumber(pl) end
      local override = reaper.GetGlobalAutomationOverride()
      local own, tracks = {}, {}
      -- Mute (the button, or a Mute envelope at 0: the button mutes even when the envelope says
      -- otherwise, measured), solo (1 solo, 2 in place; 5 and 6 are their "safe" forms) and solo
      -- defeat of every track, read every frame: none of them moves the routing snapshot.
      local S = { muted = {}, solo = {}, defeat = {} }
      for i = 0, n - 1 do
        local tr = reaper.GetTrack(proj, i)
        local k = i + 1
        tracks[k] = tr
        local so = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO")
        S.solo[k] = (so == 2 or so == 6) and 2 or (so ~= 0 and 1 or 0)
        if S.solo[k] > 0 then solo = 1 end
        S.defeat[k] = reaper.GetMediaTrackInfo_Value(tr, "B_SOLO_DEFEAT") ~= 0
        local m = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0
        if not m and override ~= 6 then
          local v = ev(proj, track_cache(c, proj, tr).env["Mute"], pos)
          if v and v < 0.5 then m = true end
        end
        S.muted[k] = m
        if m then mu[#mu + 1] = tostring(i) end -- muted itself: its meter is silent (step 8: the stage keeps it where it was)
      end
      local live = c.snap and #c.snap.tracks == n
      local liveinput = false -- a track armed and monitored: its meter changes the stage any time
      for i = 0, n - 1 do
        local tr = tracks[i + 1]
        local s = c.ms[tr]
        local x, z
        if s and not S.muted[i + 1] then x, z = MT.estimate(s, t, c.decay) end -- muted: its output is silence
        local sn = live and c.snap.tracks[i + 1]
        if sn and sn.arm then
          -- An armed track meters its input, before FX, fader and pan (measured). Monitored, its
          -- output is estimated through its own fader and pan (FX ignored); not monitored, the
          -- meter says nothing about what plays.
          if sn.recmon > 0 then liveinput = true end
          if sn.recmon > 0 and z then
            local ql, qr = HD.through(HD.matrix(params(c, proj, tr, pos, defm, defl, override)), HD.powers(x, z))
            x, z = HD.azimuth(ql, qr), ql + qr > 0 and 10 * math.log(ql + qr, 10) or nil
            ae[#ae + 1] = tostring(i)
          else
            x, z = nil, nil
          end
        end
        ax[#ax + 1] = axes_json(x, z)
        if z then own[i + 1] = { HD.powers(x, z) } end
      end
      -- Stopped (step 10a): the stage is worked out again only when something it rests on moved
      -- (stopped_key), or every STOP_REFRESH seconds (a send or a pan mode changed by a script);
      -- a track played live keeps it worked out every frame. Worked out every frame, it took most of
      -- a stopped cycle (2.2-2.6 ms at 224 tracks) and left the map 29-42 windows a second.
      local key, reuse = nil, false
      if live and play & 1 ~= 1 and c.ymap and not liveinput then
        key = stopped_key(c, proj, tracks, n, pos, S, defm, defl, override)
        local why
        if c.stk == nil then why = "none"
        elseif t - c.stk.t >= STOP_REFRESH then why = "time"
        else reuse, why = same_key(key, c.stk.key, t - c.stk.t) end
        T.stopped_n = (T.stopped_n or 0) + 1
        if reuse then T.reused_n = (T.reused_n or 0) + 1 else T.why = T.why or {}; T.why[why] = (T.why[why] or 0) + 1 end
      else
        c.stk = nil
      end
      if reuse then
        local o = c.stk.out
        ax, hx, hi, hb, hm, ha, obs, oc, ob, nl, mp, ma = o.ax, o.hx, o.hi, o.hb, o.hm, o.ha, o.obs, o.oc, o.ob, o.nl, o.mp, o.ma
        sm = 1
      else
        -- stopped: every part from its files at the edit cursor, the learned FX gains (step 9a)
        local model
        if live and play & 1 ~= 1 and c.ymap then
          c.nolevel = {}
          model = stage_model(c, proj, own, n, pos, tracks, defm, defl, override, S, pos, pos + Y_SPAN, false, c.nolevel)
          sm = 1
        end
        -- the correlations found in the last frame carry the cross power through the matrices
        local h, image, via_bus, A, approx, R = heard(proj, c, own, n, pos, tracks, defm, defl, override, S, c.yrho, model)
        if model then -- each track's own, buses included, as the model has it
          for k = 1, n do
            local p = own[k]
            ax[k] = p and p[1] + p[2] > 0 and axes_json(HD.azimuth(p[1], p[2]), 10 * math.log(p[1] + p[2], 10)) or "null"
          end
        end
        for k in pairs(via_bus or {}) do hb[#hb + 1] = tostring(k - 1) end
        for k = 1, n do
          local p = h and h[k]
          if p and p[1] + p[2] > 0 then
            hx[k] = axes_json(HD.azimuth(p[1], p[2]), 10 * math.log(p[1] + p[2], 10))
            if approx and approx[k] then ha[#ha + 1] = tostring(k - 1) end
          else
            hx[k] = "null"
            if A and own[k] and A.silenced[k] then hm[#hm + 1] = tostring(k - 1) end
          end
        end
        for b in pairs(image or {}) do if b > 0 then hi[#hi + 1] = tostring(b - 1) end end
        -- the stage's objects (graph "stage"), heard: a track, a return or a bus is its own heard
        -- X and Z, a display group its members' heard powers added up (decision 3 of step 6)
        -- and which objects are cut from the master now, by a mute (their own or one above them) or
        -- a solo elsewhere, whether or not they sound: the stage keeps them where they were last
        -- heard (step 8 review; a display group when all its members are)
        if c.stage and c.stage_n == n then
          local hp = {}
          for k = 1, n do local p = h and h[k]; if p and p[1] + p[2] > 0 then hp[k] = p end end
          local function cut(k) return S.muted[k] or (A and A.silenced[k]) or false end
          -- stopped: where each object's level comes from, by power (step 9a)
          local hbs = model and R and R.basis and HD.carry_basis(n, R.basis, R.dry, R.gbasis)
          -- and the share of the stage's power its meters measured here (step 9b review: the basis
          -- counts a part with no FX as exact, which the note took for measured)
          local hms = hbs and HD.carry_basis(n, model.meas or {}, R.dry, R.gbasis)
          local mw, mm = 0, 0
          for j, obj in ipairs(c.stage) do
            if hbs then
              local w, v, m = 0, { 0, 0, 0 }, 0
              for _, k in ipairs(obj.sum or (obj.kind == "group" and obj.members) or { obj.track }) do
                local p, b = hp[k], hbs[k]
                if p and b then
                  local x = p[1] + p[2]
                  w = w + x
                  for i = 1, 3 do v[i] = v[i] + b[i] * x end
                  m = m + (hms[k] and hms[k][1] or 0) * x
                end
              end
              ob[j] = w > 0 and string.format("[%.2f,%.2f,%.2f]", v[1] / w, v[2] / w, v[3] / w) or "null"
              if w > 0 and not obj.open then mw, mm = mw + w, mm + m end
              if obj.track and c.nolevel and c.nolevel[obj.track] and not hp[obj.track] then nl[#nl + 1] = tostring(j - 1) end
            end
          end
          if hbs and mw > 0 then mp = string.format("%.2f", mm / mw) end
          for j, ob in ipairs(c.stage) do
            local p = V.object_powers(ob, hp)
            obs[#obs + 1] = p and axes_json(HD.azimuth(p[1], p[2]), 10 * math.log(p[1] + p[2], 10)) or "null"
            local off
            if ob.kind == "group" then
              off = #(ob.members or {}) > 0
              for _, k in ipairs(ob.members or {}) do if not cut(k) then off = false; break end end
            else
              off = cut(ob.track)
            end
            if off then oc[#oc + 1] = tostring(j - 1) end
          end
        end
        -- Y and width (step 7) are worked out on a cycle of their own (spectra, below), from what
        -- this frame read; the frame carries the last result
        if live and R then
          c.yin = { n = n, own = own, h = h, A = A, R = R, tracks = tracks, pos = pos, play = play,
                    defm = defm, defl = defl, override = override, S = S,
                    steady = c.play_from ~= nil and t - c.play_from >= Y_SPAN + 0.5 }
        end
        if model then -- the master as the model has it (the mix every Z is measured against)
          local p = own[0]
          ma = p and p[1] + p[2] > 0 and axes_json(HD.azimuth(p[1], p[2]), 10 * math.log(p[1] + p[2], 10)) or "null"
        else
          ma = axes_json(MT.estimate(c.mst, t, c.decay))
        end
        c.stk = key and model and { key = key, t = t, out = { ax = ax, hx = hx, hi = hi, hb = hb, hm = hm, ha = ha, obs = obs,
          oc = oc, ob = ob, nl = nl, mp = mp, ma = ma } } or nil
      end
      local yo = c.yout
      if yo and yo.n == n and yo.stage == c.stage then ycol, oy, ym = yo.y, yo.oy, yo.ym end
      local d = c.decay
      md = string.format('{"step":%.3f,"refresh_ms":%.1f,"decay":%.1f,"vudecay":%s,"measured":%s}',
        d.step, 1000 * d.refresh, MT.decay_db_per_s(d), num(vudecay()), d.measured and "true" or "false")
    end
    T.seq = T.seq + 1
    local err = T.last_error and J.encode(T.last_error) or "null"
    return string.format('{"v":0,"seq":%d,"gseq":%d,"t":%.3f,"up":%.1f,"state":"%s","reason":%s,"play":%d,"pos":%.3f,"tabs":%d,"cost":%s,"err":%s,"solo":%d,"ma":%s,"md":%s,"a":[%s],"h":[%s],"hi":[%s],"ae":[%s],"hb":[%s],"hm":[%s],"ha":[%s],"mu":[%s],"o":[%s],"oc":[%s],"sm":%d,"ob":[%s],"mp":%s,"nl":[%s],"y":[%s],"oy":[%s],"ym":%s,"ack":%.0f,"ack_ok":%s,"ack_msg":%s,"note_n":%d,"note":%s}',
      T.seq, T.gseq, now(), now() - T.started, state, J.encode(T.reason), play, pos, (function() local k = 0 for _ in pairs(T.tabs) do k = k + 1 end return k end)(),
      T.cost, err, solo, ma, md, table.concat(ax, ","), table.concat(hx, ","), table.concat(hi, ","), table.concat(ae, ","), table.concat(hb, ","),
      table.concat(hm, ","), table.concat(ha, ","), table.concat(mu, ","), table.concat(obs, ","), table.concat(oc, ","), sm, table.concat(ob, ","), mp, table.concat(nl, ","), ycol, oy, ym,
      T.ack, T.ack_ok == nil and "null" or tostring(T.ack_ok), T.ack_msg and J.encode(T.ack_msg) or "null", T.note_n, T.note and J.encode(T.note) or "null")
  end

  local function tick()
    if getx("owner") ~= token then T.running = false; T.reason = "replaced by a newer instance"; return end
    if getx("command") == "stop" then setx("command", ""); T.running = false; T.reason = "stopped on request"; return end
    if getx("debug_fault") == "1" then setx("debug_fault", ""); error("injected fault (test)") end

    local t = now()
    local proj = reaper.EnumProjects(-1)
    local c, key = tab_cache(proj)
    local switched = T.cur ~= c
    T.cur = c

    -- an action changed the choices ("ping" = "<n>|<what happened>"): read them now, not within
    -- the second; a command from the page: apply it (both are cheap reads when nothing came)
    local ping = getx("ping")
    if ping ~= T.ping then
      if T.ping ~= nil then
        c.store_t = -1e9
        local pn, msg = ping:match("^(%d+)|(.*)$")
        if pn then T.note_n, T.note = T.note_n + 1, msg end
      end
      T.ping = ping
      local id = math.tointeger(tonumber(getx("all_cmd")))
      if T.light and not math.type(opts.light) and id and id > 0 then T.light_id = id end
    end
    local raw = getx("cmd")
    if raw ~= "" then setx("cmd", ""); run_command(proj, c, raw) end -- consumed: never applied twice

    local store_changed, ev = false, nil
    if switched or t - c.store_t >= STORE_EVERY then
      c.store_t = t
      ev = S.follow(proj, c.st)
      store_changed = ev ~= "same"
    end
    if c.store_dirty then store_changed, c.store_dirty = true, false end
    if store_changed or not c.hist then remember(c, ev) end

    local sc = reaper.GetProjectStateChangeCount(proj)
    local count_changed = reaper.CountTracks(proj) ~= c.n
    local state_due = sc ~= c.sc and t - c.graph_t >= GRAPH_EVERY
    if switched or count_changed or sc ~= c.cache_sc or t - c.cache_t >= CACHE_EVERY then c.cache_t, c.cache_sc = t, sc end
    if switched or store_changed or count_changed or state_due or c.reclass or t - c.snap_t >= SNAP_EVERY then
      if state_due then c.sc, c.graph_t = sc, t end
      -- The graph (~20 ms to build and encode at 224 tracks) is built only when something in
      -- it changed: names, parents and routing are in the snapshot, colours are checked here.
      -- A knob turned or a fader moved changes the state counter but none of these.
      local roles_changed = refresh_roles(proj, c, t)
      local colors = colors_of(proj)
      if switched or store_changed or count_changed or roles_changed or colors ~= c.colors then
        c.colors, c.sc, c.graph_t = colors, sc, t
        T.kind = "graph, "
        local g, n = build_graph(proj, c)
        c.n = n
        local json = J.encode(g)
        if switched or json ~= c.json then c.json = json; publish_graph(g) end
      end
    end

    if t - T.last_prune >= PRUNE_EVERY then
      T.last_prune = t
      for k, tc in pairs(T.tabs) do
        if k ~= key and not reaper.ValidatePtr2(0, tc.proj, "ReaProject*") then T.tabs[k] = nil end
      end
      if c.ymap then YM.prune(c.ymap, proj) end -- tracks deleted
    end

    read_meters(proj, c, t)


    -- Defer ticks come about every 31 ms, so frames are due on a running schedule rather than
    -- "100 ms since the last one", which would round up to every fourth tick (8 per second).
    -- Step 7: besides reading meters, a cycle publishes a frame, or gathers or finishes Y and
    -- width (about five times a second, never with a frame); then the spectrum map reads files
    -- with what is left of TICK_TARGET (at most Y_BUDGET), around the play position first. A
    -- small project leaves the map nearly every cycle; at 224 tracks a frame alone fills one.
    local framed = t >= T.next_pub
    if framed then
      T.next_pub = math.max(T.next_pub + PUBLISH_EVERY, t - PUBLISH_EVERY / 2)
      setx("frame", frame("running"))
      T.kind_ms.frame = 1000 * (now() - t)
      T.fcost_i = T.fcost_i % COST_WINDOW + 1
      T.fcosts[T.fcost_i] = now() - t
      T.kind = T.kind .. "frame"
      if #c.cand > 0 then net_listen(proj, c) end
      if c.heard_n > 0 and reaper.GetPlayStateEx(proj) & 1 == 1 then
        net_release(proj, c, t - (c.nr_t or t))
        c.nr_t = t
      else
        c.nr_t = nil
      end
    elseif c.yjob then
      spectra_finish(c, proj)
      T.kind_ms.finish = 1000 * (now() - t)
      T.kind = T.kind .. "finish"
    elseif c.yin and t - (c.y_t or 0) >= Y_EVERY then
      c.y_t = t
      spectra_gather(c, proj)
      T.kind_ms.gather = 1000 * (now() - t)
      T.kind = T.kind .. "gather"
    else
      sections_tick(c, proj, t)
      T.kind_ms.section = 1000 * (now() - t)
      T.kind = T.kind .. "section"
    end
    local left = math.min(Y_BUDGET, TICK_TARGET - (now() - t))
    if left > 0.0003 and c.yneed and #c.yneed > 0 then
      c.ymap = c.ymap or YM.new()
      local playing = reaper.GetPlayStateEx(proj) & 1 == 1
      local ypos = playing and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
      YM.work(c.ymap, proj, c.yneed, ypos, playing, reaper.GetProjectLength(proj), left)
    end
    run_jobs()
    if framed then
      -- the "Show all or chosen tracks" light follows the active tab (set again whenever it
      -- differs, so another script or engine that set it cannot leave it wrong)
      if T.light_id > 0 then
        local doc = c.st.doc
        local want = (doc and doc.view and doc.view.mode == "all") and 1 or 0
        if reaper.GetToggleCommandStateEx(0, T.light_id) ~= want then
          reaper.SetToggleCommandState(0, T.light_id, want)
          reaper.RefreshToolbar2(0, T.light_id)
        end
      end
    end
  end

  -- d: how long this tick took; gap: time since the previous tick started (REAPER's pace,
  -- which anything else holding REAPER's main thread would stretch).
  local function record_cost(d, gap)
    T.cost_i = T.cost_i % COST_WINDOW + 1
    T.costs[T.cost_i] = d
    T.gaps[T.cost_i] = gap or 0
    T.ticks = T.ticks + 1
    local t = now()
    if d > T.max_d then T.max_d, T.max_at, T.max_kind = d, t - T.started, T.kind end
    if (gap or 0) > T.max_gap then T.max_gap, T.max_gap_at = gap, t - T.started end
    if (gap or 0) > 0.25 then T.long_gaps = (T.long_gaps or 0) + 1 end -- REAPER held for over 0.25 s
    T.kind = ""
    if t - T.cost_t >= 1 then
      local s, gs, fs = {}, {}, {}
      for i, v in ipairs(T.costs) do s[i] = v end
      for i, v in ipairs(T.gaps) do gs[i] = v end
      for i, v in ipairs(T.fcosts) do fs[i] = v end
      table.sort(s); table.sort(gs); table.sort(fs)
      T.cost = string.format('{"ms_med":%.3f,"ms_p95":%.3f,"ms_max":%.3f,"ticks_per_s":%.1f,"gap_ms_med":%.1f,"gap_ms_p95":%.1f,"gap_ms_max":%.1f,'
        .. '"frame_ms_med":%.3f,"frame_ms_p95":%.3f,"max_ms":%.1f,"max_at":%.0f,"max_kind":"%s","gap_max_ms":%.0f,"gap_max_at":%.0f,"long_gaps":%d,"mem_kb":%.0f,"stopped":%d,"reused":%d,"why":%s}',
        1000 * percentile(s, 0.5), 1000 * percentile(s, 0.95), 1000 * (s[#s] or 0), T.ticks / math.max(t - T.cost_t, 1e-6),
        1000 * percentile(gs, 0.5), 1000 * percentile(gs, 0.95), 1000 * (gs[#gs] or 0),
        1000 * percentile(fs, 0.5), 1000 * percentile(fs, 0.95), 1000 * T.max_d, T.max_at, T.max_kind, 1000 * T.max_gap, T.max_gap_at, T.long_gaps or 0,
        collectgarbage("count"), T.stopped_n or 0, T.reused_n or 0, (function()
          local w = {}
          for k, v in pairs(T.why or {}) do w[#w + 1] = k .. ":" .. v end
          table.sort(w)
          return J.encode(table.concat(w, " "))
        end)())
      T.cost_t, T.ticks = t, 0
    end
  end

  reaper.atexit(function()
    pcall(function()
      if T.reason == "" then T.reason = "the action was run again" end
      setx("frame", frame("stopped"))
    end)
    pcall(finish_jobs) -- what playing taught (step 9a), every write under way finished first
    for _, tc in pairs(T.tabs) do pcall(save_learning, tc, tc.proj, true) end
    pcall(function() if getx("owner") == token then setx("owner", "") end end)
    if reaper.set_action_options then pcall(reaper.set_action_options, 8) end
  end)

  local port = E.web_port()
  if not port then
    T.running = false
    T.reason = "no web interface"
    if opts.open_browser ~= false then
      -- the user started it (step 11): what to click, in a box they cannot miss, and Preferences
      -- opened on a yes (a test engine never shows a box: it would hold every script)
      if reaper.MB(E.WEB_HELP, "ReaperForVisual", 4) == 6 then E.open_prefs() end
    else
      reaper.ShowConsoleMsg("ReaperForVisual needs REAPER's web interface: " .. E.WEB_HELP:gsub("\n+", " ") .. "\n")
    end
  elseif opts.open_browser ~= false and not E.page_recent() then
    -- 127.0.0.1: "localhost" first tries IPv6 and waits 2 s. The web server does not map a
    -- folder to its index.html, so the file is named.
    local url = string.format("http://127.0.0.1:%d/rfv/index.html", port)
    E.open_url(url)
  end

  local function loop()
    if not T.running then return end
    local t0 = now()
    local gap = T.last_t0 and (t0 - T.last_t0) or nil
    T.last_t0 = t0
    local ok, err = xpcall(tick, debug.traceback)
    if ok then
      T.errors = 0
    else
      T.errors = T.errors + 1
      T.last_error = tostring(err):sub(1, 600)
      setx("error", T.last_error)
      if T.errors >= MAX_ERRORS then T.running = false; T.reason = "stopped after " .. MAX_ERRORS .. " errors in a row" end
    end
    record_cost(now() - t0, gap)
    if T.running then reaper.defer(loop) end
  end
  reaper.defer(loop)
end

return E
