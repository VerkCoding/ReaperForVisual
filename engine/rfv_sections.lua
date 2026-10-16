-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The song's sections (roadmap step 9b; DESIGN.md "Sections", decisions for step 9, 4). Where
-- they come from is the project's choice in its .rfv.json, sections.source:
--   "regions" (the default): each region is a section, named after it; a region over 90 % of the
--            song or more is a render region, not a section (Brauerize and the Tiki Horea
--            template have one over the whole song, 0-249 s, and their sections as markers).
--            Without regions, markers whose name starts with "#" (as "markers#").
--   "markers#": each marker named "#..." starts a section that runs to the next such marker or
--            the song's end, named after the rest of its name; other markers are notes ("Check
--            Gain Vox" in the owner's projects) and are left out.
--   "markers": every marker starts a section, to the next one or the song's end; a marker at the
--            song's end or later (Brauerize's "end") and a section under 2 s are left out.
--   "off":   none.
-- Pure Lua apart from SC.read.

local SC = {}
SC.RENDER_SHARE = 0.9  -- a region this share of the song or more is a render region
SC.MIN_LEN = 2.0       -- shortest section from markers, in seconds
SC.SOURCES = { regions = true, ["markers#"] = true, markers = true, off = true }

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

-- From marks = { { rgn = bool, pos, rend, name }, ... } and the song's length (seconds):
-- { { name, a, b }, ... } in order of start, and the source used ("regions", "markers#",
-- "markers" or "off").
function SC.build(marks, source, len)
  source = SC.SOURCES[source or ""] and source or "regions"
  local out = {}
  if source == "off" then return out, "off" end
  local function from_markers(only_hash)
    local ms = {}
    for _, m in ipairs(marks) do
      if not m.rgn and m.pos < len - 0.5 then
        local nm = trim(m.name)
        if not only_hash then ms[#ms + 1] = { pos = m.pos, name = nm }
        elseif nm:sub(1, 1) == "#" then ms[#ms + 1] = { pos = m.pos, name = trim(nm:sub(2)) } end
      end
    end
    table.sort(ms, function(x, y) return x.pos < y.pos end)
    for i, m in ipairs(ms) do
      local b = ms[i + 1] and ms[i + 1].pos or len
      if b - m.pos >= (only_hash and 0.01 or SC.MIN_LEN) then
        out[#out + 1] = { name = m.name ~= "" and m.name or ("Section " .. (#out + 1)), a = m.pos, b = b }
      end
    end
  end
  if source == "regions" then
    for _, m in ipairs(marks) do
      if m.rgn and m.rend > m.pos and (len <= 0 or (m.rend - m.pos) < SC.RENDER_SHARE * len) then
        local nm = trim(m.name)
        out[#out + 1] = { name = nm ~= "" and nm or ("Region " .. (#out + 1)), a = m.pos, b = m.rend }
      end
    end
    table.sort(out, function(x, y) return x.a < y.a or (x.a == y.a and x.b < y.b) end)
    if #out > 0 then return out, "regions" end
    from_markers(true)
    return out, #out > 0 and "markers#" or "regions"
  end
  from_markers(source == "markers#")
  return out, source
end

-- A project's regions and markers, as SC.build takes them.
function SC.read(proj)
  local marks = {}
  local i = 0
  while true do
    local ok, rgn, pos, rend, name = reaper.EnumProjectMarkers3(proj, i)
    if not ok or ok == 0 then break end
    marks[#marks + 1] = { rgn = rgn, pos = pos, rend = rend, name = name }
    i = i + 1
  end
  return marks
end

return SC
