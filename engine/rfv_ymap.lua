-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The spectrum map (roadmap step 7, decision 1): per track, blocks of BLOCK seconds of its files
-- analysed with PER windows each (10 a second; step 7 research: one a second put Y 0.18 octave
-- off in median, five to ten 0.02-0.09), read through the track's audio accessor. Filled within
-- a time budget per defer cycle: first the blocks around the play position (the readout and
-- what comes next), one window per block at a time so every needed track gets an estimate
-- early; then the rest of the song in the background. Step 9's stopped mode and sections read
-- the same blocks.
--
-- Accessors live for one cycle only: made for a track just checked to be valid, used, and
-- destroyed before the cycle ends (~6 microseconds each). One kept across cycles would be a
-- snapshot (measured: it keeps reading an old item layout until AudioAccessorUpdate) of a track
-- the user may delete or a tab the user may close in between, and what REAPER does with an
-- accessor whose track is gone was not tried on purpose (it could take REAPER down).
--
-- A track's blocks are dropped when its items change. REAPER flags only some edits, late (moves,
-- mute, items added, take FX added or bypassed; not volumes, take pan, lengths, offsets, playrate
-- or fades), so each needed track's items are fingerprinted whenever the project's state counter
-- moves. A take FX parameter change is not seen (rare; noted in DESIGN.md).
--
-- Reading files changes nothing in the project (measured: dirty, undo and the state counter stay
-- put while 12,000 windows are read).

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local SP = dofile(HERE .. "rfv_spectrum.lua")

local YM = {}
YM.BLOCK, YM.PER = 0.5, 5
YM.SPAN = 2.0                  -- the readout: seconds of files behind Y and width (as Z's window)
YM.VISIT = 4                   -- windows for one track before the next
YM.BEHIND, YM.AHEAD = 2.5, 2.5 -- the range filled first, around the play position
local now = reaper.time_precise

function YM.new()
  return { tracks = {}, ans = {}, sc = nil, rr = 1, windows = 0, ms = 0, wcost = 0.0004, resets = 0 }
end

-- An analyser per sample rate: a track's files are read at their own rate, which saves REAPER
-- resampling them (measured on the band fixture's 44.1 kHz files: 0.29 ms a window against 0.43
-- at 48 kHz). Y is in Hz, so the rate changes nothing else.
local function analyser(map, sr)
  local an = map.ans[sr]
  if not an then an = SP.new(SP.N, sr); map.ans[sr] = an end
  return an
end

-- What a track's items are now, as one string (compared, never parsed), whether it plays MIDI
-- (its files then say nothing of its sound), and the sample rate of its first audio file. A take's
-- source by its file and type, not by its pointer: REAPER makes new source objects when the project
-- is opened again, and a pointer in it made every track's items read as changed after a restart
-- (the learning file kept the fingerprint hashed: what the meters measured was forgotten; step 9b
-- acceptance on OGW, 2026-10-16). Not by its length either: set offline (REAPER's "offlineinact",
-- whenever REAPER goes to the background), a source reads length 0, and the owner's map was
-- dropped 50 times in 33 minutes (step 10b, measured); the item's own length and offset are in.
local function source_id(src)
  if not src then return "-" end
  return ("%s|%s"):format(reaper.GetMediaSourceType(src) or "?", reaper.GetMediaSourceFileName(src) or "")
end

function YM.fingerprint(tr)
  local parts, midi, sr = {}, false, nil
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local function v(k) return reaper.GetMediaItemInfo_Value(it, k) end
    local s = ("%.6f %.6f %d %.6g %.6f %.6f"):format(v("D_POSITION"), v("D_LENGTH"), v("B_MUTE"), v("D_VOL"), v("D_FADEINLEN"), v("D_FADEOUTLEN"))
    local tk = reaper.GetActiveTake(it)
    if tk and reaper.TakeIsMIDI(tk) then midi = true
    elseif tk and not sr then
      local rate = reaper.GetMediaSourceSampleRate(reaper.GetMediaItemTake_Source(tk))
      if rate and rate >= 8000 then sr = math.floor(rate + 0.5) end
    end
    if tk then
      local function w(k) return reaper.GetMediaItemTakeInfo_Value(tk, k) end
      s = s .. (" %.6f %.6g %.6g %.6g %.6g %d %s"):format(w("D_STARTOFFS"), w("D_PLAYRATE"), w("D_PITCH"), w("D_VOL"), w("D_PAN"),
        w("I_CHANMODE"), source_id(reaper.GetMediaItemTake_Source(tk)))
      for f = 0, reaper.TakeFX_GetCount(tk) - 1 do s = s .. (reaper.TakeFX_GetEnabled(tk, f) and " fx" or " off") end
    end
    parts[#parts + 1] = s
  end
  return table.concat(parts, "|"), midi, sr
end

local function reset(e)
  e.blocks, e.done, e.complete, e.bg, e.ndone, e.audio = {}, {}, false, nil, 0, nil
  e.coarse, e.cg, e.nb1 = false, nil, 0 -- the coarse pass (step 9a): blocks with a window at least
end

-- Kept for callers that end a map; accessors never outlive a cycle, so there is nothing to free.
function YM.destroy(map) map.tracks = {} end

-- Forget tracks no longer in the project.
function YM.prune(map, proj)
  for g, e in pairs(map.tracks) do
    if not reaper.ValidatePtr2(proj, e.tr, "MediaTrack*") then map.tracks[g] = nil end
  end
end

-- Work for at most `budget` seconds. need: { { track, guid }, ... } in priority order; pos: the
-- play position (or the edit cursor), playing: true while it moves; len: the project's length.
function YM.work(map, proj, need, pos, playing, len, budget)
  local t0 = now()
  local deadline = t0 + budget
  local accs = {} -- this cycle's accessors, by entry
  local did = 0   -- windows read this cycle (at least one is, whatever the budget says)
  local function acc_of(e)
    local a = accs[e]
    if a == nil then
      a = reaper.CreateTrackAudioAccessor(e.tr) or false
      accs[e] = a
      if a then e.st, e.en = reaper.GetAudioAccessorStartTime(a), reaper.GetAudioAccessorEndTime(a) end
    end
    return a
  end
  -- one window of block b of entry e; true when one was read
  local function step(e, b)
    local d = e.done[b] or 0
    if d >= YM.PER then return false end
    local a = acc_of(e)
    if not a then return false end
    local t = b * YM.BLOCK + d * (YM.BLOCK / YM.PER)
    local an = analyser(map, e.sr or SP.SR)
    if t + an.len <= e.st or t >= e.en then -- no item there: done without reading
      e.done[b] = YM.PER
      e.ndone = e.ndone + (YM.PER - d)
      if d == 0 then e.nb1 = e.nb1 + 1 end
      return false
    end
    if d == 0 then e.nb1 = e.nb1 + 1 end
    local s = e.blocks[b]
    if not s then s = SP.zero(); e.blocks[b] = s end
    local c0 = now()
    if SP.window(an, a, t, s) == "audio" then e.audio = true end
    map.wcost = 0.9 * map.wcost + 0.1 * (now() - c0) -- what a window costs, for the budget
    did = did + 1
    e.done[b] = d + 1
    e.ndone = e.ndone + 1
    map.windows = map.windows + 1
    return true
  end
  local function finish()
    for _, a in pairs(accs) do if a then reaper.DestroyAudioAccessor(a) end end
    local t = now()
    map.ms = 1000 * (t - t0)
    if not map.rt or t - map.rt >= 1 then -- windows read per second, over the last second
      if map.rt then map.wps = (map.windows - map.rw) / (t - map.rt) end
      map.rt, map.rw = t, map.windows
    end
  end

  -- the needed tracks that are still valid; their items re-read when the state counter moved
  local sc = reaper.GetProjectStateChangeCount(proj)
  local moved = sc ~= map.sc
  map.sc = sc
  local es = {}
  for _, nd in ipairs(need) do
    local tr, g = nd[1], nd[2]
    if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
      local e = map.tracks[g]
      if e and e.tr ~= tr then e = nil; map.resets = (map.resets or 0) + 1 end -- the same GUID, another track (the tab was reopened)
      if not e then
        e = { tr = tr, guid = g }
        e.fp, e.midi, e.sr = YM.fingerprint(tr)
        reset(e)
        map.tracks[g] = e
      elseif moved then
        e.check = true
      end
      if e.check and now() < deadline then
        e.check = nil
        local fp, midi, sr = YM.fingerprint(tr)
        e.midi = midi
        if fp ~= e.fp or sr ~= e.sr then
          e.fp, e.sr = fp, sr
          reset(e)
          -- how often a track's blocks were dropped, and the last one's name (step 9b acceptance:
          -- half the owner's map dropped at once, cause not found from the outside)
          map.resets = (map.resets or 0) + 1
          local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          map.reset_last = nm
        end
      end
      es[#es + 1] = e
    end
  end
  if #es == 0 then return finish() end

  -- 1. the readout (the last SPAN seconds while playing, the next ones while stopped), then the
  -- rest of the range around the position; each one window per block at a time (level by
  -- level), so every needed track has an estimate early
  local B = YM.BLOCK
  local b0, b1 = math.floor(math.max(0, pos - YM.BEHIND) / B), math.floor((pos + YM.AHEAD) / B)
  local bp = math.floor(pos / B)
  local first, rest = {}, {}
  if playing then
    local r0 = math.floor(math.max(0, pos - YM.SPAN) / B)
    for b = bp, r0, -1 do first[#first + 1] = b end
    for b = bp + 1, b1 do rest[#rest + 1] = b end
    for b = r0 - 1, b0, -1 do rest[#rest + 1] = b end
  else
    local r1 = math.floor((pos + YM.SPAN) / B)
    for b = bp, r1 do first[#first + 1] = b end
    for b = r1 + 1, b1 do rest[#rest + 1] = b end
    for b = bp - 1, b0, -1 do rest[#rest + 1] = b end
  end
  -- Up to VISIT windows for one track before the next: the first read on a fresh accessor costs
  -- more (measured on the band fixture: 0.65 ms alone, 0.45 ms each in fives, 0.40 kept). The
  -- next cycle goes on from the next track, so every track is served in turn.
  local n = #es
  if map.rr > n then map.rr = 1 end
  local function serve(e, order) -- true when the budget is spent
    local got = 0
    for level = 1, YM.PER do
      for _, b in ipairs(order) do
        if (e.done[b] or 0) < level then
          if did > 0 and now() + map.wcost > deadline then return true end
          if step(e, b) then got = got + 1 end
          if now() >= deadline then return true end
          if got >= YM.VISIT then return false end
        end
      end
    end
    return false
  end
  for _, order in ipairs({ first, rest }) do
    for j = 0, n - 1 do
      local i = (map.rr + j - 1) % n + 1
      if serve(es[i], order) then map.rr = i % n + 1; return finish() end
    end
  end
  -- 2. the rest of the song, from there on, track by track: first one window a block for every
  -- track (a coarse pass: stopped, the stage stands anywhere in the song within minutes; step 7
  -- review U3: the owner's song took 8 to 17 minutes densely), then every block filled
  local last = math.floor(len / B)
  for pass = 1, 2 do
    local level, flag, cur = 1, "coarse", "cg"
    if pass == 2 then level, flag, cur = YM.PER, "complete", "bg" end
    for j = 0, n - 1 do
      local e = es[(map.rr + j - 1) % n + 1]
      if not e[flag] then
        e[cur] = e[cur] or b1 + 1
        local tries = 0
        while tries <= last + 1 do
          if e[cur] > last then e[cur] = 0 end
          if (e.done[e[cur]] or 0) < level then
            if did > 0 and now() + map.wcost > deadline then return finish() end
            step(e, e[cur])
            if now() >= deadline then return finish() end
          else
            e[cur], tries = e[cur] + 1, tries + 1
          end
        end
        e[flag] = true
      end
    end
  end
  return finish()
end

-- A track's stats over [t0, t1) (the blocks in skip left out): the blocks it touches, how much of
-- them is read (0 .. 1), its entry, the windows read there, silent ones and blocks with no item
-- included (a level is the stats' power over them: step 9b review, a part that plays in half a
-- section is half as loud there on average, not as loud as where it plays), and the share of the
-- blocks with a window read at least. nil stats when nothing is read yet, or when the files hold
-- no sound there (windows read then tell the one from the other).
function YM.stats(map, guid, t0, t1, skip)
  local e = map.tracks[guid]
  if not e then return nil, 0, nil, 0, 0 end
  local B = YM.BLOCK
  local b0, b1 = math.floor(math.max(0, t0) / B), math.floor(math.max(0, t1 - 1e-9) / B)
  if e.complete and not e.audio then -- read through, nothing in its files
    local nb = 0
    for b = b0, b1 do if not (skip and skip[b]) then nb = nb + 1 end end
    return nil, 1, e, nb * YM.PER, 1
  end
  local s, done, want, nb, touched = nil, 0, 0, 0, 0
  for b = b0, b1 do
    if not (skip and skip[b]) then
      local d = e.done[b] or 0
      want, nb = want + YM.PER, nb + 1
      done = done + d
      if d > 0 then touched = touched + 1 end
      local x = e.blocks[b]
      if x and x[1] + x[2] > 0 then s = SP.add(s or SP.zero(), x) end
    end
  end
  return s, want > 0 and done / want or 1, e, done, nb > 0 and touched / nb or 1
end

-- How many windows of [t0, t1) are read, over every track in the map, and how many tracks were
-- dropped so far: a cheap sign that what the stage at the edit cursor rests on was read further
-- or started again (step 10a: stopped, the stage is worked out again only then).
function YM.read_near(map, t0, t1)
  local B = YM.BLOCK
  local b0, b1 = math.floor(math.max(0, t0) / B), math.floor(math.max(0, t1 - 1e-9) / B)
  local n = 0
  for _, e in pairs(map.tracks) do
    local d = e.done
    for b = b0, b1 do n = n + (d[b] or 0) end
  end
  return n, map.resets or 0
end

-- How much of the whole song is read for the needed tracks (0 .. 1), densely and coarsely (a
-- window in every block at least).
function YM.progress(map, need, len)
  local nb = math.floor(len / YM.BLOCK) + 1
  local per = nb * YM.PER
  local done, want, c1 = 0, 0, 0
  for _, nd in ipairs(need) do
    local e = map.tracks[nd[2]]
    want = want + per
    done = done + (e and (e.complete and per or math.min(per, e.ndone)) or 0)
    c1 = c1 + (e and ((e.complete or e.coarse) and nb or math.min(nb, e.nb1 or 0)) or 0)
  end
  if want == 0 then return 1, 1 end
  return done / want, c1 / (want / YM.PER)
end

return YM
