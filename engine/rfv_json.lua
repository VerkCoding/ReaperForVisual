-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Small JSON encoder and decoder (RFC 8259) for ReaperForVisual's files and messages.
--
-- Decoded arrays and objects carry a marker so they encode back the same way, even when
-- empty. Build new ones with J.array{} and J.object{}; a plain table encodes as an array
-- when its keys are exactly 1..n and n > 0, otherwise as an object. JSON null decodes to
-- J.null, so a key holding null is kept. Object keys are written sorted, so a file that did
-- not change in meaning does not change in bytes.
--
-- Every module loads its own copy of this file (dofile), so the markers are recognised by their
-- tag, not by identity: an array made by one copy is an array to every other (step 6: an empty
-- list made by rfv_view.lua was written as {} by the store's copy).

local J = {}

local ARRAY = { __jsontype = "array" }
local OBJECT = { __jsontype = "object" }
J.null = setmetatable({}, { __tostring = function() return "null" end, __jsontype = "null" })

function J.array(t) return setmetatable(t or {}, ARRAY) end
function J.object(t) return setmetatable(t or {}, OBJECT) end
local function tag(v)
  local mt = type(v) == "table" and getmetatable(v)
  return mt and mt.__jsontype or nil
end
function J.is_array(t) return tag(t) == "array" end
function J.is_null(v) return v == J.null or tag(v) == "null" end

-- encoding ------------------------------------------------------------------------------

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function enc_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function enc_number(n)
  if n ~= n or n == math.huge or n == -math.huge then error("cannot encode " .. tostring(n) .. " in JSON") end
  if math.type(n) == "integer" then return tostring(n) end
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  local s = string.format("%.14g", n)
  if tonumber(s) ~= n then s = string.format("%.17g", n) end
  return s
end

local function kind(t)
  local tg = tag(t)
  if tg == "array" or tg == "object" then return tg end
  local n = #t
  if n == 0 then return "object" end
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 or k > n then return "object" end
  end
  return "array"
end

local function enc(v, indent, depth, seen)
  local tv = type(v)
  if v == nil or J.is_null(v) then return "null"
  elseif tv == "boolean" then return tostring(v)
  elseif tv == "number" then return enc_number(v)
  elseif tv == "string" then return enc_string(v)
  elseif tv ~= "table" then error("cannot encode a " .. tv .. " in JSON") end
  if seen[v] then error("cannot encode a table that contains itself") end
  seen[v] = true
  local nl, pad, pad_in, colon = "", "", "", ":"
  if indent then
    nl = "\n"; pad = string.rep(indent, depth); pad_in = string.rep(indent, depth + 1); colon = ": "
  end
  local parts = {}
  local out
  if kind(v) == "array" then
    for i = 1, #v do parts[i] = pad_in .. enc(v[i], indent, depth + 1, seen) end
    out = #parts == 0 and "[]" or ("[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]")
  else
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= "string" then error("JSON object keys must be strings, got " .. type(k)) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do parts[i] = pad_in .. enc_string(k) .. colon .. enc(v[k], indent, depth + 1, seen) end
    out = #parts == 0 and "{}" or ("{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}")
  end
  seen[v] = nil
  return out
end

-- J.encode(value [, indent]): indent is a string such as "  " for readable output.
function J.encode(v, indent) return enc(v, indent, 0, {}) end

-- decoding ------------------------------------------------------------------------------

local function err(s, i, what) error(("JSON: %s at byte %d"):format(what, i), 0) end

local function skip(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local dec

local function dec_string(s, i) -- s:sub(i, i) == '"'
  local out, j = {}, i + 1
  while true do
    local a, b = s:find('["\\%c]', j)
    if not a then err(s, i, "unterminated string") end
    out[#out + 1] = s:sub(j, a - 1)
    local c = s:sub(a, a)
    if c == '"' then return table.concat(out), a + 1 end
    if c ~= "\\" then err(s, a, "control character in string") end
    local e = s:sub(a + 1, a + 1)
    local simple = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[e]
    if simple then
      out[#out + 1] = simple; j = a + 2
    elseif e == "u" then
      local hex = s:match("^%x%x%x%x", a + 2)
      if not hex then err(s, a, "bad \\u escape") end
      local cp = tonumber(hex, 16); j = a + 6
      if cp >= 0xD800 and cp <= 0xDBFF then
        local lo = s:match("^\\u(%x%x%x%x)", j)
        local lv = lo and tonumber(lo, 16)
        if not lv or lv < 0xDC00 or lv > 0xDFFF then err(s, a, "unpaired surrogate") end
        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lv - 0xDC00); j = j + 6
      elseif cp >= 0xDC00 and cp <= 0xDFFF then
        err(s, a, "unpaired surrogate")
      end
      out[#out + 1] = utf8.char(cp)
    else
      err(s, a, "bad escape")
    end
  end
end

local function dec_number(s, i)
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not num or num == "-" then err(s, i, "bad number") end
  local n = tonumber(num)
  if not n then err(s, i, "bad number") end
  return n, i + #num
end

function dec(s, i, depth)
  if depth > 200 then err(s, i, "nesting too deep") end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = J.object{}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then err(s, i, "expected a key") end
      local k; k, i = dec_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
      local v; v, i = dec(s, i + 1, depth + 1)
      t[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then err(s, i, "expected ',' or '}'") end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    local t = J.array{}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      local v; v, i = dec(s, i, depth + 1)
      t[#t + 1] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then err(s, i, "expected ',' or ']'") end
      i = i + 1
    end
  elseif c == '"' then return dec_string(s, i)
  elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then return J.null, i + 4
  elseif c:match("[-%d]") then return dec_number(s, i)
  end
  err(s, i, c == "" and "unexpected end" or ("unexpected '" .. c .. "'"))
end

-- J.decode(text) returns value, or nil and a message. A UTF-8 byte order mark is skipped.
function J.decode(s)
  if type(s) ~= "string" then return nil, "JSON: input is not a string" end
  local start = s:sub(1, 3) == "\239\187\191" and 4 or 1
  local ok, v, i = pcall(dec, s, start, 0)
  if not ok then return nil, v end
  i = skip(s, i)
  if i <= #s then return nil, ("JSON: trailing characters at byte %d"):format(i) end
  return v
end

return J
