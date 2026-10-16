-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 6, live: the page's commands to the engine (ExtState "cmd" = "<seq>|<bytes>|<json>"),
-- written here the way the web interface stores them after decoding a request. Each command's
-- answer comes back in the frame ("ack", "ack_ok", "ack_msg"); the graph must show its effect.
-- Covers: show by track index, a command cut short on the way (the web interface truncates
-- requests over ~1 KB without a word), a resent (old) sequence number, another tab, a graph
-- that changed under the command, role and main-path corrections and their undoing, a group
-- made, renamed and removed, all/chosen, taking REAPER's selection, forgetting a deleted track,
-- adopting choices found beside the project, an unknown command, Undo and Redo (step 6 review);
-- then, playing, the stage's objects get heard X and Z (a group: its members' heard powers added
-- up).
-- Tracks: Drums (folder) > Kick, Snare; Bass; Vox (sends to Verb); Verb; Lead (master send
-- off, equal sends to BusA and BusB: a tie); BusA; BusB.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local L = dofile(HERE .. "fixtures" .. SEP .. "lib.lua")
local H = dofile(HERE .. "harness.lua")
local EL = dofile(HERE .. "engine_lib.lua")
local J = EL.json
local S = dofile(reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "ReaperForVisual" .. SEP .. "rfv_store.lua")
local FAKE = "{DEADBEEF-0000-4000-8000-000000000000}"

local function idx(g, name) for _, t in ipairs(g.tracks) do if t.name == name then return t.i end end end
local function trk(g, name) return g.tracks[idx(g, name) + 1] end
local function names(g, list)
  local by, out = {}, {}
  for _, t in ipairs(g.tracks) do by[t.guid:upper()] = t.name end
  for _, x in ipairs(list or {}) do out[#out + 1] = by[tostring(x):upper()] or "?" end
  table.sort(out)
  return table.concat(out, ",")
end
local function has(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end

-- Write a command. o.len: the length to claim; o.cut: bytes of the body actually stored;
-- o.seq: a sequence number to use instead of the next one.
local function send(ctx, obj, o)
  o = o or {}
  local seq = o.seq
  if not seq then ctx.seq = (ctx.seq or 1000) + 1; seq = ctx.seq end
  if obj.tab == nil then obj.tab = ctx.tabstr end
  local body = J.encode(J.object(obj))
  local stored = o.cut and body:sub(1, o.cut) or body
  reaper.SetExtState(EL.SECTION, "cmd", ("%d|%d|%s"):format(seq, o.len or #body, stored), false)
  return seq
end

-- name, send(ctx, g) -> sequence number it should be answered under (nil: none expected),
-- want_ok (true / false / nil = no answer at all), check(ctx, g, f) -> ok, detail
local CASES = {
  { "show Kick and Snare by index", function(ctx, g) return send(ctx, { op = "show", k = J.array{ idx(g, "Kick"), idx(g, "Snare") }, gseq = g.gseq }) end, true,
    function(ctx, g) local v = names(g, g.view.tracks); return v == "Kick,Snare", "view " .. v end },
  { "a command cut short on the way", function(ctx, g) return send(ctx, { op = "add", k = J.array{ idx(g, "Bass") }, gseq = g.gseq }, { cut = 20 }) end, false,
    function(ctx, g, f) local v = names(g, g.view.tracks); return v == "Kick,Snare" and f.ack_msg:find("cut short") ~= nil, "view " .. v .. "; " .. f.ack_msg end },
  { "an old sequence number again (a resend)", function(ctx, g) send(ctx, { op = "add", k = J.array{ idx(g, "Bass") }, gseq = g.gseq }, { seq = 1001 }); return nil end, nil,
    function(ctx, g, f) local v = names(g, g.view.tracks); return v == "Kick,Snare" and f.ack == ctx.last_ack, "ignored: view " .. v .. ", ack still " .. string.format("%.0f", f.ack) end },
  { "another project tab", function(ctx, g) return send(ctx, { op = "add", k = J.array{ idx(g, "Bass") }, gseq = g.gseq, tab = "userdata: 0000000000000001" }) end, false,
    function(ctx, g, f) return names(g, g.view.tracks) == "Kick,Snare", f.ack_msg end },
  { "a graph that changed under the command", function(ctx, g) return send(ctx, { op = "add", k = J.array{ idx(g, "Bass") }, gseq = g.gseq - 1 }) end, false,
    function(ctx, g, f) return names(g, g.view.tracks) == "Kick,Snare" and f.ack_msg:find("sent again") ~= nil, f.ack_msg end },
  { "Vox's role set to return", function(ctx, g) return send(ctx, { op = "role", g = trk(g, "Vox").guid, r = "return" }) end, true,
    function(ctx, g) local t = trk(g, "Vox"); return t.role == "return" and has(t.flags, "user"), ("role %s, flags %s; %s"):format(t.role, table.concat(t.flags, " "), t.reason) end },
  { "Vox's role back to the routing's", function(ctx, g) return send(ctx, { op = "role", g = trk(g, "Vox").guid, r = J.null }) end, true,
    function(ctx, g) local t = trk(g, "Vox"); return t.role == "source" and not has(t.flags, "user"), "role " .. t.role end },
  { "an unknown role", function(ctx, g) return send(ctx, { op = "role", g = trk(g, "Vox").guid, r = "lead" }) end, false,
    function(ctx, g, f) return trk(g, "Vox").role == "source", f.ack_msg end },
  { "Lead's main path set to BusB", function(ctx, g) return send(ctx, { op = "path", g = trk(g, "Lead").guid, d = trk(g, "BusB").guid }) end, true,
    function(ctx, g) local t = trk(g, "Lead"); return t.dry == idx(g, "BusB") and has(t.flags, "user"), ("dry %s (BusB %d), flags %s"):format(tostring(t.dry), idx(g, "BusB"), table.concat(t.flags, " ")) end },
  { "Lead's main path back to the routing's", function(ctx, g) return send(ctx, { op = "path", g = trk(g, "Lead").guid, d = J.null }) end, true,
    function(ctx, g) local t = trk(g, "Lead"); return t.dry == idx(g, "BusA") and has(t.flags, "tie"), ("dry %s (BusA %d), flags %s"):format(tostring(t.dry), idx(g, "BusA"), table.concat(t.flags, " ")) end },
  { "group Kick and Snare", function(ctx, g) return send(ctx, { op = "group", k = J.array{ idx(g, "Kick"), idx(g, "Snare") }, gseq = g.gseq }) end, true,
    function(ctx, g) local gr = g.view.groups[1]; return gr and gr.name == "Group 1" and names(g, gr.tracks) == "Kick,Snare" and g.stage.objects[1].kind == "group", gr and ("group %s: %s"):format(gr.name, names(g, gr.tracks)) or "no group" end },
  { "rename the group", function(ctx, g) return send(ctx, { op = "rename", i = 0, name = "Drum group — café" }) end, true,
    function(ctx, g) local gr = g.view.groups[1]; return gr and gr.name == "Drum group — café" and g.stage.objects[1].name == "Drum group — café", gr and gr.name or "-" end },
  { "a rename to nothing", function(ctx, g) return send(ctx, { op = "rename", i = 0, name = "   " }) end, false,
    function(ctx, g, f) return g.view.groups[1].name == "Drum group — café", f.ack_msg end },
  { "show all", function(ctx, g) return send(ctx, { op = "mode", m = "toggle" }) end, true,
    function(ctx, g) local kinds = {}; for _, o in ipairs(g.stage.objects) do kinds[#kinds + 1] = o.kind .. ":" .. g.tracks[o.track + 1].name end
      return g.stage.mode == "all", "stage " .. table.concat(kinds, ", ") end },
  { "back to the chosen", function(ctx, g) return send(ctx, { op = "mode", m = "chosen" }) end, true,
    function(ctx, g) return g.stage.mode == "chosen", "mode " .. g.stage.mode end },
  { "take REAPER's selection (Bass) and add it", function(ctx, g)
      local P = ctx.proj
      for i = 0, reaper.CountTracks(P) - 1 do reaper.SetTrackSelected(reaper.GetTrack(P, i), false) end
      reaper.SetTrackSelected(reaper.GetTrack(P, idx(g, "Bass")), true)
      return send(ctx, { op = "take", how = "add" }) end, true,
    function(ctx, g) local v = names(g, g.view.tracks); return v == "Bass,Kick,Snare", "view " .. v end },
  { "add a track that is not in the project", function(ctx, g) return send(ctx, { op = "add", g = J.array{ FAKE } }) end, true,
    function(ctx, g) local m = g.store.missing; return #m == 1 and m[1].guid == FAKE, ("%d missing"):format(#m) end },
  { "forget it", function(ctx, g) return send(ctx, { op = "forget", g = J.array{ FAKE } }) end, true,
    function(ctx, g) return #g.store.missing == 0 and names(g, g.view.tracks) == "Bass,Kick,Snare", ("%d missing, view %s"):format(#g.store.missing, names(g, g.view.tracks)) end },
  { "remove the group", function(ctx, g) return send(ctx, { op = "ungroup", i = 0 }) end, true,
    function(ctx, g) return #g.view.groups == 0 and names(g, g.view.tracks) == "Bass,Kick,Snare", ("%d groups"):format(#g.view.groups) end },
  -- step 6 review U1: the page's Undo and Redo walk back and forth through what the engine saw
  { "undo: the group is back", function(ctx, g) return send(ctx, { op = "undo" }) end, true,
    function(ctx, g) local gr = g.view.groups[1]
      return gr and gr.name == "Drum group — café" and names(g, g.view.tracks) == "Bass,Kick,Snare" and g.history.redo == 1,
        ("group %s, view %s, history %d/%d"):format(gr and gr.name or "none", names(g, g.view.tracks), g.history.undo, g.history.redo) end },
  { "undo again: the forgotten track is back", function(ctx, g) return send(ctx, { op = "undo" }) end, true,
    function(ctx, g) local m = g.store.missing; return #m == 1 and m[1].guid == FAKE and g.history.redo == 2, ("%d missing, history %d/%d"):format(#m, g.history.undo, g.history.redo) end },
  { "redo: forgotten again", function(ctx, g) return send(ctx, { op = "redo" }) end, true,
    function(ctx, g) return #g.store.missing == 0 and #g.view.groups == 1, ("%d missing, %d groups"):format(#g.store.missing, #g.view.groups) end },
  { "redo: the group removed again", function(ctx, g) return send(ctx, { op = "redo" }) end, true,
    function(ctx, g) return #g.view.groups == 0 and g.history.redo == 0, ("%d groups, history %d/%d"):format(#g.view.groups, g.history.undo, g.history.redo) end },
  { "nothing more to redo", function(ctx, g) return send(ctx, { op = "redo" }) end, false,
    function(ctx, g, f) return #g.view.groups == 0 and f.ack_msg:find("nothing to redo") ~= nil, f.ack_msg end },
  { "a new change clears what could be redone", function(ctx, g)
      ctx.undo_seq = send(ctx, { op = "undo" })
      return nil end, nil,
    function(ctx, g, f) return f.ack == ctx.undo_seq and f.ack_ok and #g.view.groups == 1 and g.history.redo == 1, ("undone: %d groups, history %d/%d"):format(#g.view.groups, g.history.undo, g.history.redo) end },
  { "... (that change: ungroup by hand)", function(ctx, g) return send(ctx, { op = "ungroup", i = 0 }) end, true,
    function(ctx, g) return #g.view.groups == 0 and g.history.redo == 0, ("%d groups, history %d/%d"):format(#g.view.groups, g.history.undo, g.history.redo) end },
  { "an unknown command", function(ctx, g) return send(ctx, { op = "explode" }) end, false,
    function(ctx, g, f) return f.ack_msg:find("unknown") ~= nil, f.ack_msg end },
  { "choices found beside the project, adopted", function(ctx, g)
      -- the choices move to another name in the folder; the project's own are gone
      local fh = io.open(ctx.side, "rb")
      if not fh then
        local list, i = {}, 0
        local dir = ctx.dir
        reaper.EnumerateFiles(dir, -1)
        while reaper.EnumerateFiles(dir, i) do list[#list + 1] = reaper.EnumerateFiles(dir, i); i = i + 1 end
        local _, fn = reaper.EnumProjects(-1)
        ctx.ok = false
        ctx.lines[#ctx.lines + 1] = ("  no %s; the folder holds %s; the project is %s; the choices in ExtState: %s  <-- FAIL"):format(ctx.side,
          table.concat(list, ", "), fn, reaper.GetExtState("ReaperForVisual", "unsaved " .. ctx.tabstr):sub(1, 120))
        return nil
      end
      local text = fh:read("a")
      fh:close()
      local f = assert(io.open(ctx.other, "wb")); f:write(text); f:close()
      local ok, err = os.remove(ctx.side)
      ctx.removed = ok and "removed" or ("not removed: " .. tostring(err))
      return nil end, nil,
    function(ctx, g)
      local c = g.store.candidates
      ctx.cand = c[1] and c[1].path
      local direct = S.adoption_candidates(ctx.proj)
      return c[1] ~= nil and c[1].path:lower() == ctx.other:lower() and g.view == J.null,
        ("own choices %s; %d candidate(s) in the graph (%s), %d found directly (%s); view %s"):format(ctx.removed, #c, tostring(ctx.cand),
          #direct, direct[1] and direct[1].path or "-", g.view == J.null and "none" or "still there") end },
  { "adopt them", function(ctx, g) return send(ctx, { op = "adopt", path = ctx.cand or "" }) end, true,
    function(ctx, g) local v = g.view ~= J.null and names(g, g.view.tracks) or "-"; local back = S.read(ctx.side)
      return v == "Bass,Kick,Snare" and back ~= nil, "view " .. v .. ", written beside the project " .. tostring(back ~= nil) end },
}

local steps = {
  function(tab, ctx)
    local sine = L.env().signals .. SEP .. "sine1k_m12.wav"
    reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(tab), "B_MUTE", 1)
    L.track(tab, "Drums", 1)
    L.item(L.track(tab, "Kick", 0), sine, 0, 60)
    L.item(L.track(tab, "Snare", -1), sine, 0, 60)
    L.item(L.track(tab, "Bass", 0), sine, 0, 60)
    local vox = L.track(tab, "Vox", 0); L.item(vox, sine, 0, 60)
    local verb = L.track(tab, "Verb", 0)
    L.send(vox, verb, 0.3)
    local lead = L.track(tab, "Lead", 0, { mainsend = false }); L.item(lead, sine, 0, 60)
    local a, b = L.track(tab, "BusA", 0), L.track(tab, "BusB", 0)
    L.send(lead, a, 0.5); L.send(lead, b, 0.5)
    local dir = H.tmpdir("view-commands")
    ctx.dir = dir
    ctx.rpp = dir .. SEP .. "vc.rpp"
    ctx.side = S.sidecar_path(ctx.rpp)
    ctx.other = dir .. SEP .. "other.rfv.json"
    for _, x in ipairs({ ctx.side, ctx.side .. ".tmp", ctx.side .. ".old", ctx.other }) do os.remove(x) end
    ctx.tab = L.save_reopen(tab, ctx.rpp)
    ctx.proj = ctx.tab -- the harness takes ctx.tab back after this step
    ctx.tabstr = tostring(ctx.tab)
    EL.reset()
    ctx.ecmd, ctx.epath = EL.register("rfv_engine_test_cmds")
    EL.run_later(ctx.ecmd)
    ctx.lines, ctx.ok, ctx.case = {}, true, 0
    return nil, "built and saved; engine starting", 2
  end,
}
-- one step per case: judge the previous case, then send this one
local function judge(ctx)
  local c = CASES[ctx.case]
  if not c then return end
  local f, g = EL.read("frame"), EL.read("graph")
  local answered = ctx.want_seq and f.ack == ctx.want_seq
  local good = true
  if c[3] == nil then good = true else good = answered and f.ack_ok == c[3] end
  if g.view == J.null and c[1] ~= "choices found beside the project, adopted" then
    local fh = io.open(ctx.side, "rb")
    local text = fh and fh:read("a") or "(no file)"
    if fh then fh:close() end
    ctx.ok = false
    ctx.lines[#ctx.lines + 1] = ("  %-46s the view is gone: store error %s; file: %s; answer %s %s: %s; graph tab %s, sent for %s  <-- FAIL"):format(c[1],
      g.store.error ~= J.null and (g.store.error.code .. " " .. g.store.error.msg) or "none", text:sub(1, 300):gsub("%s+", " "),
      string.format("%.0f", f.ack), tostring(f.ack_ok), tostring(f.ack_msg), tostring(g.tab), tostring(ctx.tabstr))
    return
  end
  local ok2, detail = c[4](ctx, g, f)
  good = good and ok2
  if not good then ctx.ok = false end
  if f.ack and f.ack ~= J.null then ctx.last_ack = f.ack end
  ctx.lines[#ctx.lines + 1] = ("  %-46s %s%s"):format(c[1], tostring(detail), good and "" or ("   <-- FAIL (answer %s, ok %s)"):format(tostring(answered), tostring(f.ack_ok)))
end
for i = 1, #CASES do
  steps[#steps + 1] = function(tab, ctx)
    if i == 1 then -- the test's own engine must be running, not one an earlier run left behind
      local f = EL.read("frame")
      local owner = reaper.GetExtState(EL.SECTION, "owner")
      if not f or f.state ~= "running" or owner == "" then
        return false, ("the test engine is not running: frame state %s, owner '%s', launcher %s"):format(f and f.state or "none", owner, tostring(ctx.ecmd))
      end
    end
    judge(ctx)
    ctx.case = i
    local g = EL.read("graph")
    ctx.want_seq = CASES[i][2](ctx, g)
    return nil, nil, CASES[i][3] == nil and 1.3 or 0.3
  end
end
-- the last case, then the stage while playing
steps[#steps + 1] = function(tab, ctx)
  judge(ctx)
  local g = EL.read("graph")
  ctx.group_seq = send(ctx, { op = "group", k = J.array{ idx(g, "Kick"), idx(g, "Snare") }, gseq = g.gseq })
  return nil, nil, 0.4
end
steps[#steps + 1] = function(tab, ctx)
  local f = EL.read("frame")
  if f.ack ~= ctx.group_seq or not f.ack_ok then ctx.ok = false; ctx.lines[#ctx.lines + 1] = "  group again: " .. tostring(f.ack_msg) .. "  <-- FAIL" end
  reaper.defer(function()
    reaper.Main_OnCommand(40101, 0)
    reaper.SetEditCurPos2(ctx.proj, 0, false, false)
    reaper.OnPlayButtonEx(ctx.proj)
  end)
  return nil, "grouped Kick and Snare again; playing", 3.5
end
steps[#steps + 1] = function(tab, ctx)
  local f, g = EL.read("frame"), EL.read("graph")
  reaper.OnStopButtonEx(ctx.proj)
  EL.stop()
  EL.unregister(ctx.epath)
  local objs, o = g.stage.objects, f.o
  local lines = {}
  local good = #objs == #o and #objs > 0
  local T30 = math.tan(math.rad(30))
  local function powers(v) -- [x, z] back to left and right powers
    local p = 10 ^ (v[2] / 10)
    local q = math.tan(math.rad(v[1])) / T30
    local l, r = (1 - q) / 2, (1 + q) / 2
    return p * l * l / (l * l + r * r), p * r * r / (l * l + r * r)
  end
  for j, ob in ipairs(objs) do
    local v = o[j]
    local label = ob.kind == "group" and ob.name or g.tracks[ob.track + 1].name
    if v == J.null then good = false; lines[#lines + 1] = "  " .. label .. ": silent  <-- FAIL"
    else
      local line = ("  %s %s: X %.1f, Z %.1f"):format(ob.kind, label, v[1], v[2])
      if ob.kind == "group" then -- its members' heard powers added up (those no other member carries)
        local sl, sr = 0, 0
        for _, m in ipairs(ob.sum ~= J.null and ob.sum or ob.members) do local h = f.h[m + 1]; local a, b = powers(h); sl, sr = sl + a, sr + b end
        local want = 10 * math.log(sl + sr, 10)
        local d = math.abs(want - v[2])
        if d > 0.15 then good = false end
        line = line .. (" (members' heard powers added up: %.1f)%s"):format(want, d > 0.15 and "  <-- FAIL" or "")
      end
      lines[#lines + 1] = line
    end
  end
  local all = ctx.ok and good
  return all, table.concat(ctx.lines, "\n") .. "\nwhile playing, the stage's objects:\n" .. table.concat(lines, "\n")
end

return {
  name = "view-commands",
  steps = steps,
  cleanup = function(ctx) EL.stop(); if ctx.epath then EL.unregister(ctx.epath) end end,
}
