-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- What the engine learns while the song plays, for the stage when it stops (roadmap step 9a,
-- decision 1): values in dB per key (each track's power as its meter measured it, before its
-- fader and pan; a track's FX gain over its files; a bus's FX gain) and per block of the song.
-- Stopped, the meters say nothing: where the song played, each part stands where its meter put
-- it then (step 9a review F1: on the owner's mix, files read in short windows missed drum hits,
-- 2 to 11 dB off what the meters heard); elsewhere its level comes from its files through its
-- fader and pan, times the FX gain learned here, else the median of what was learned elsewhere
-- in the song, else nothing (step 9 research, band fixture: the FX gain not known, 3.0 dB off in
-- median per section, p90 7.4; learned on the other sections, 0.47 dB, p90 2.35).
--
-- A sample covers the seconds it was measured over (the meters' 2 s); every block in them takes
-- it. A block holds the mean of its samples until CAP of them, then an exponential mean, so a
-- place played again after a change in the mix moves to its new value within a few passes.
-- Kept in memory while the engine runs. Pure Lua.

local LN = {}
LN.BLOCK = 0.5
LN.CAP = 20
-- A block not learned takes the nearest block learned within NEAR blocks (1 s) as its own: an FX
-- gain moves slowly, and learning starts only 2.5 s into playing (the meters' window), so the
-- first block where playing started, where the edit cursor goes back on stop, is never learned
-- itself (step 9a review).
LN.NEAR = 2

local floor = math.floor

-- Keys ending in ":l" or ":r" hold levels (a power in dB): their samples and blocks are averaged
-- as powers. Averaged in dB, a part that comes and goes reads low (the backing vocals of the band
-- fixture, 4 dB: step 9a review F1). Other keys (gains) are averaged in dB.
local function is_level(key) local t = key:sub(-2); return t == ":l" or t == ":r" end
local function lin(x) return 10 ^ (x / 10) end
local function db(p) return p > 0 and 10 * math.log(p, 10) or -150 end

function LN.new() return { keys = {} } end

local function blocks(t0, t1)
  local B = LN.BLOCK
  return floor(math.max(0, t0) / B), floor(math.max(0, t1 - 1e-9) / B)
end

-- One sample v (dB) of key, measured over [t0, t1) in song seconds.
function LN.add(L, key, t0, t1, v)
  if v ~= v or v == math.huge or v == -math.huge then return end
  local e = L.keys[key]
  if not e then e = { v = {}, n = {}, med = nil, count = 0 }; L.keys[key] = e end
  local b0, b1 = blocks(t0, t1)
  local level = is_level(key)
  for b = b0, b1 do
    local x, k = e.v[b], e.n[b] or 0
    if not x then e.count = e.count + 1 end
    k = math.min(k + 1, LN.CAP)
    if not x then e.v[b] = v
    elseif level then e.v[b] = db(lin(x) + (lin(v) - lin(x)) / k)
    else e.v[b] = x + (v - x) / k end
    e.n[b] = k
  end
  e.med = nil
end

-- The mean of values, as powers for a level.
local function mean(sum, got, level) return level and db(sum / got) or sum / got end

local function median(e)
  if e.med == nil then
    local v = {}
    for _, x in pairs(e.v) do v[#v + 1] = x end
    if #v == 0 then e.med = false
    else
      table.sort(v)
      local m = (#v + 1) // 2
      e.med = #v % 2 == 1 and v[m] or (v[m] + v[m + 1]) / 2
    end
  end
  return e.med or nil
end

-- The blocks of [t0, t1) learned (a learned neighbour within NEAR standing in): their sum (as
-- powers for a level), how many, and how many blocks [t0, t1) spans; set (optional) takes them.
local function gather(e, t0, t1, level, set)
  local b0, b1 = blocks(t0, t1)
  local sum, got = 0, 0
  for b = b0, b1 do
    local x = e.v[b]
    for d = 1, LN.NEAR do
      if x then break end
      x = e.v[b - d] or e.v[b + d]
    end
    if x then
      sum, got = sum + (level and lin(x) or x), got + 1
      if set then set[b] = true end
    end
  end
  return sum, got, b1 - b0 + 1
end

-- The value of key over [t0, t1): the mean of its blocks learned there, blended with the median
-- of every block learned for the blocks not learned there. Returns value (dB) and the share of
-- [t0, t1) learned there (0 .. 1); nil when nothing was ever learned for key.
function LN.at(L, key, t0, t1)
  local e = L.keys[key]
  if not e or e.count == 0 then return nil, 0 end
  local level = is_level(key)
  local sum, got, all = gather(e, t0, t1, level)
  local share = got / all
  if got == all then return mean(sum, got, level), 1 end
  local med = median(e)
  if got == 0 then return med, 0 end
  if level then return db(share * sum / got + (1 - share) * lin(med)), share end
  return share * (sum / got) + (1 - share) * med, share
end

-- The mean of key's blocks learned in [t0, t1) only (a learned neighbour within NEAR standing in),
-- and the share of [t0, t1) they cover; nil when none: for what was measured at a place (a
-- level), which says nothing of another place. set (optional) takes the blocks counted (the
-- block numbers are YM's too: both are 0.5 s), so the rest can come from elsewhere (step 9b review).
function LN.here(L, key, t0, t1, set)
  local e = L.keys[key]
  if not e or e.count == 0 then return nil, 0 end
  local level = is_level(key)
  local sum, got, all = gather(e, t0, t1, level, set)
  if got == 0 then return nil, 0 end
  return mean(sum, got, level), got / all
end

-- Forget every key that starts with prefix (a track's, when its FX change).
function LN.forget(L, prefix)
  for key in pairs(L.keys) do
    if key:sub(1, #prefix) == prefix then L.keys[key] = nil end
  end
end

-- How many keys, and blocks learned in all.
function LN.size(L)
  local k, b = 0, 0
  for _, e in pairs(L.keys) do k, b = k + 1, b + e.count end
  return k, b
end

-- One key as its file text, "block:value:samples ..." in block order, values to 0.01 dB; nil
-- when it has no block (step 10a: the engine writes the file a few keys at a time).
function LN.key_text(L, key)
  local e = L.keys[key]
  if not e then return nil end
  local bs = {}
  for b in pairs(e.v) do bs[#bs + 1] = b end
  if #bs == 0 then return nil end
  table.sort(bs)
  local parts = {}
  for i, b in ipairs(bs) do parts[i] = ("%d:%.2f:%d"):format(b, floor(e.v[b] * 100 + 0.5) / 100, e.n[b] or 1) end
  return table.concat(parts, " ")
end

-- As plain tables, for a file: { [key] = { { block, value, samples }, ... } }, values to 0.01 dB.
function LN.dump(L)
  local out = {}
  for key, e in pairs(L.keys) do
    local list = {}
    for b, x in pairs(e.v) do list[#list + 1] = { b, floor(x * 100 + 0.5) / 100, e.n[b] or 1 } end
    table.sort(list, function(p, q) return p[1] < q[1] end)
    if #list > 0 then out[key] = list end
  end
  return out
end

-- One key back from its text in the file, "block:value:samples ..." (LN.dump's form as the engine
-- writes it), straight into the learning: parsing into tables first took 42 ms for the owner's
-- 110 KB file (step 10a). True when the key had a block.
function LN.load_text(L, key, text)
  local e = { v = {}, n = {}, med = nil, count = 0 }
  for b, x, k in text:gmatch("(%-?%d+):(%-?[%d%.]+):(%d+)") do
    b, x, k = math.tointeger(tonumber(b)), tonumber(x), tonumber(k) or 1
    if b and x and x == x then
      if not e.v[b] then e.count = e.count + 1 end
      e.v[b], e.n[b] = x, math.max(1, math.min(LN.CAP, k))
    end
  end
  if e.count == 0 then return false end
  L.keys[key] = e
  return true
end

-- Back from LN.dump's form; keys keep(key) refuses are left out. Returns the keys taken.
function LN.load(L, t, keep)
  local n = 0
  for key, list in pairs(t or {}) do
    if type(key) == "string" and type(list) == "table" and (not keep or keep(key)) then
      local e = { v = {}, n = {}, med = nil, count = 0 }
      for _, r in ipairs(list) do
        local b, x, k = math.tointeger(r[1]), tonumber(r[2]), tonumber(r[3]) or 1
        if b and x and x == x then
          if not e.v[b] then e.count = e.count + 1 end
          e.v[b], e.n[b] = x, math.max(1, math.min(LN.CAP, k))
        end
      end
      if e.count > 0 then L.keys[key], n = e, n + 1 end
    end
  end
  return n
end

return LN
