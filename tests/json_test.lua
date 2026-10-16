-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- engine/rfv_json.lua: round trips, escapes, errors, stability and speed.

local SEP = package.config:sub(1, 1)

return {
  name = "json",
  no_tab = true,
  run = function()
    local J = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_json.lua")
    local fails, out = {}, {}
    local function check(name, cond, info) if not cond then fails[#fails + 1] = name .. (info and (": " .. info) or "") end end

    local function same(a, b)
      if a == b then return true end
      if type(a) ~= "table" or type(b) ~= "table" then return false end
      if J.is_array(a) ~= J.is_array(b) then return false end
      for k, v in pairs(a) do if not same(v, b[k]) then return false end end
      for k in pairs(b) do if a[k] == nil then return false end end
      return true
    end

    -- 1. round trip of every kind of value
    local text = [==[{"format":"rfv","version":0,"name":"Drum kit \"main\" — café \\ tab\there","n":[0,-3,2.5,1e-3,-1.25E+2,9007199254740991],
      "ok":true,"no":false,"nothing":null,"empty_a":[],"empty_o":{},"nest":{"a":[{"b":[[]]}]},"esc":"\u00e9\ud83c\udfb5\n"}]==]
    local v, e = J.decode(text)
    check("decode", v ~= nil, e)
    if v then
      check("utf8 kept", v.name == 'Drum kit "main" — café \\ tab\there')
      check("unicode escape", v.esc == "é🎵\n", v.esc)
      check("numbers", v.n[1] == 0 and v.n[2] == -3 and v.n[3] == 2.5 and v.n[4] == 0.001 and v.n[5] == -125 and v.n[6] == 9007199254740991)
      check("null kept", v.nothing == J.null)
      check("empty array kind", J.encode(v.empty_a) == "[]")
      check("empty object kind", J.encode(v.empty_o) == "{}")
      local once = J.encode(v, "  ")
      local again = J.encode(J.decode(once), "  ")
      check("stable bytes", once == again)
      check("deep equal", same(v, J.decode(once)))
      check("compact equals pretty", same(J.decode(J.encode(v)), J.decode(once)))
      out[#out + 1] = ("pretty form %d bytes, compact %d bytes"):format(#once, #J.encode(v))
    end

    -- 2. plain Lua tables
    check("plain array", J.encode({ 1, 2, 3 }) == "[1,2,3]")
    check("plain object sorted", J.encode({ b = 1, a = 2 }) == '{"a":2,"b":1}')
    check("control char", J.encode("a\1b") == '"a\\u0001b"')
    check("float", J.encode(0.1) == "0.1" and J.encode(1 / 3) == string.format("%.17g", 1 / 3))
    check("bom skipped", (J.decode("\239\187\191[1]") or {})[1] == 1)

    -- 3. malformed input is refused with a message, never an exception
    for _, bad in ipairs({ "[1,]", '{"a":1,}', '"open', '"\\x"', "[1 2]", "{1:2}", "tru", "", "[1]x", '"\\ud83c"' }) do
      local r, m = J.decode(bad)
      check("refuse " .. bad, r == nil and type(m) == "string")
    end
    local ok = pcall(J.encode, 0 / 0)
    check("NaN refused", not ok)

    -- 4. speed on a view of 1,000 tracks
    local guids = J.array{}
    for i = 1, 1000 do guids[i] = string.format("{%08X-1234-5678-9ABC-%012X}", i, i * 7919) end
    local doc = { format = "rfv", version = 0, view = { tracks = guids } }
    local t0 = reaper.time_precise()
    local s = J.encode(doc, "  ")
    local t1 = reaper.time_precise()
    local back = J.decode(s)
    local t2 = reaper.time_precise()
    check("1000 guids round trip", back and #back.view.tracks == 1000 and back.view.tracks[1000] == guids[1000])
    out[#out + 1] = ("1,000 GUIDs: %d bytes, encode %.1f ms, decode %.1f ms"):format(#s, 1000 * (t1 - t0), 1000 * (t2 - t1))

    if #fails > 0 then out[#out + 1] = "failed: " .. table.concat(fails, "; ") end
    return #fails == 0, table.concat(out, "\n")
  end,
}
