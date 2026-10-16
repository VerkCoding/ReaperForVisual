-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- The View menu (step 6 review, U4-b): every view action in one popup where the mouse is, for a
-- user to put on one key or in one menu of their own. Nothing to import and nothing of the
-- user's menus or toolbars is replaced. The items:
--   Show selected tracks / Add / Remove / Group   (greyed while no track is selected)
--   Show the whole mix                            (ticked while the whole mix is shown)
--   Undo view change / Redo view change           (the engine keeps that history: greyed while
--                                                  it is not running or has nothing to take back)
-- M.state reads what the menu needs, M.build turns it into gfx.showmenu's text and the
-- operation behind each item, M.choose does one; M.run is the action.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local S = dofile(HERE .. "rfv_store.lua")
local A = dofile(HERE .. "rfv_actions.lua")

local M = {}

-- What the menu shows, for the active project tab.
function M.state(proj)
  proj = proj or reaper.EnumProjects(-1)
  local section = _G.RFV_SECTION or A.SECTION
  local st = {}
  S.follow(proj, st)
  local s = { selected = #(A.selected(proj)), mode = st.doc and st.doc.view and st.doc.view.mode or "chosen",
              engine = false, undo = 0, redo = 0 }
  local frame = reaper.GetExtState(section, "frame")
  local t = tonumber(frame:match('"t":([%d%.]+)'))
  s.engine = frame:find('"state":"running"', 1, true) ~= nil and t ~= nil and reaper.time_precise() - t <= 2
  if s.engine then
    -- the history counts of this tab, from the graph (keys are written sorted: redo, undo)
    local graph = reaper.GetExtState(section, "graph")
    if graph:match('"tab":"([^"]*)"') == tostring(proj) then
      local redo, undo = graph:match('"history":{"redo":(%d+),"undo":(%d+)}')
      s.undo, s.redo = tonumber(undo) or 0, tonumber(redo) or 0
    end
  end
  return s
end

-- gfx.showmenu's text and, for each item it can return (1, 2, ... in order; separators are not
-- items), the operation.
function M.build(s)
  local items, ops = {}, {}
  local function item(label, op, grey, tick)
    items[#items + 1] = (grey and "#" or "") .. (tick and "!" or "") .. label
    ops[#ops + 1] = op
  end
  local none = s.selected == 0
  local hint = none and " (select tracks first)" or ""
  item("Show selected tracks" .. hint, "show", none)
  item("Add selected tracks" .. hint, "add", none)
  item("Remove selected tracks" .. hint, "remove", none)
  item("Group selected tracks" .. hint, "group", none)
  items[#items + 1] = ""
  item("Show the whole mix", "all", false, s.mode == "all")
  items[#items + 1] = ""
  local off = not s.engine and " (start ReaperForVisual first)" or ""
  item("Undo view change" .. (off ~= "" and off or (s.undo == 0 and " (nothing to undo)" or "")), "undo", not s.engine or s.undo == 0)
  item("Redo view change" .. (off ~= "" and off or (s.redo == 0 and " (nothing to redo)" or "")), "redo", not s.engine or s.redo == 0)
  return table.concat(items, "|"), ops
end

-- Do one operation. Returns ok, message.
function M.choose(op, proj)
  if op == "undo" or op == "redo" then
    if A.command({ op = op }, proj) then return true, op .. " sent to the engine" end
    return false, "ReaperForVisual is not running: start it to undo or redo"
  end
  return A.run(op)
end

-- The menu where the mouse is; returns the item picked (0: none). gfx.showmenu is tried
-- without a window first: on REAPER 7.82 (Windows) it shows at the mouse that way (the owner's
-- first use, 2026-10-13). If it comes back at once with nothing (no menu was shown: nobody
-- closes a menu within 50 ms), as it might elsewhere, a window of no size is opened at the
-- mouse to hold the menu. Which way was taken is kept in ExtState "menu_path".
function M.popup(text)
  local x, y = reaper.GetMousePosition()
  local t0 = reaper.time_precise()
  gfx.x, gfx.y = x, y
  local pick = gfx.showmenu(text)
  local how = "without a window"
  if pick == 0 and reaper.time_precise() - t0 < 0.05 then
    gfx.init("ReaperForVisual", 0, 0, 0, x, y)
    gfx.x, gfx.y = 0, 0
    pick = gfx.showmenu(text)
    gfx.quit()
    how = "in a window at the mouse"
  end
  reaper.SetExtState(_G.RFV_SECTION or A.SECTION, "menu_path",
    ("%s: item %d after %.2f s"):format(how, pick, reaper.time_precise() - t0), false)
  return pick
end

-- The action: the menu, then the chosen operation.
function M.run()
  local s = M.state()
  local text, ops = M.build(s)
  local pick = M.popup(text)
  if ops[pick] then return M.choose(ops[pick]) end
  return nil, "nothing chosen"
end

return M
