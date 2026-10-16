-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Step 9a, method only: what the engine learns while playing (engine/rfv_learn.lua) and the
-- stage worked out from it when stopped (rfv_heard.lua's HD.fill, HD.degrade, HD.carry_basis,
-- and HD.propagate with fixed gains), on numbers known by arithmetic. Nothing plays.

local SEP = package.config:sub(1, 1)
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local ENG = HERE .. ".." .. SEP .. "engine" .. SEP
local LN = dofile(ENG .. "rfv_learn.lua")
local HD = dofile(ENG .. "rfv_heard.lua")

return {
  name = "stopped-logic",
  steps = { function()
    local out, bad = {}, 0
    local function check(what, ok, detail)
      if not ok then bad = bad + 1 end
      out[#out + 1] = ("  %-58s %s%s"):format(what, detail, ok and "" or "   <-- FAIL")
    end
    local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 1e-9) end
    local function vec(v) return v and ("{%.2f, %.2f, %.2f}"):format(v[1], v[2], v[3]) or "nil" end
    local function same(v, w) return v and w and near(v[1], w[1], 1e-9) and near(v[2], w[2], 1e-9) and near(v[3], w[3], 1e-9) end

    out[#out + 1] = "learning (rfv_learn.lua): blocks of 0.5 s"
    local L = LN.new()
    LN.add(L, "a:g", 0, 2, 3.0)
    local v, s = LN.at(L, "a:g", 0, 2)
    check("learned there: its value, all of it here", near(v, 3) and s == 1, ("%.2f dB, here %.2f"):format(v, s))
    v, s = LN.at(L, "a:g", 10, 12)
    check("never learned there: the median elsewhere", near(v, 3) and s == 0, ("%.2f dB, here %.2f"):format(v, s))
    LN.add(L, "a:g", 4, 6, 9.0)
    v, s = LN.at(L, "a:g", 10, 12)
    check("... the median of every block learned (3 x 4, 9 x 4)", near(v, 6) and s == 0, ("%.2f dB"):format(v))
    -- a quarter learned there (the rest beyond a learned neighbour's 1 s): blended with the median
    local H = LN.new()
    LN.add(H, "h:g", 0, 2, 3.0)
    LN.add(H, "h:g", 10, 12, 9.0)
    v, s = LN.at(H, "h:g", 2.5, 4.5)
    check("a quarter learned there: blended with the median", near(v, 5.25) and near(s, 0.25), ("%.2f dB, here %.2f"):format(v, s))
    check("a key never learned: nothing", LN.at(L, "b:g", 0, 2) == nil, "nil")
    for _ = 1, 30 do LN.add(L, "c:g", 0, 0.5, 0) end
    LN.add(L, "c:g", 0, 0.5, 10)
    v = LN.at(L, "c:g", 0, 0.5)
    check("a block played again moves by 1/CAP a sample", near(v, 10 / LN.CAP), ("%.2f dB"):format(v))
    LN.add(L, "c:g", 0, 0.5, 0 / 0)
    check("... a NaN sample is ignored", near(LN.at(L, "c:g", 0, 0.5), 10 / LN.CAP), "ok")
    -- where playing started: learning begins 2.5 s in, so the first block is never learned itself
    -- (step 9a review); within 1 s a learned neighbour stands for it
    local P = LN.new()
    LN.add(P, "p:g", 10.5, 12.5, -4)
    v, s = LN.at(P, "p:g", 10, 12)
    check("the block where playing started: its neighbour's", near(v, -4) and s == 1, ("%.2f dB, here %.2f"):format(v, s))
    v, s = LN.at(P, "p:g", 12.5, 14.5) -- learned to 12.5 s: blocks to 13.5 s stand in, not beyond
    check("... but not more than 1 s on", near(s, 0.5), ("here %.2f"):format(s))
    -- a level measured at a place says nothing of another: LN.here takes only what was learned there
    v, s = LN.here(H, "h:g", 2.5, 4.5)
    check("what was learned where a quarter was: that quarter's", near(v, 3) and near(s, 0.25), ("%.2f dB, here %.2f"):format(v, s))
    check("... where nothing was learned: nothing", LN.here(H, "h:g", 6, 8) == nil, "nil")
    -- the blocks it counted (step 9b review: a section's other blocks come from the files): 2.5-4.5 s
    -- is blocks 5-8; block 3 (learned, to 2 s) stands for block 5 (within 1 s), not for 6 to 8
    local set = {}
    LN.here(H, "h:g", 2.5, 4.5, set)
    local got = {}
    for b in pairs(set) do got[#got + 1] = b end
    table.sort(got)
    check("... and which blocks those are", table.concat(got, ",") == "5", "{" .. table.concat(got, ",") .. "}")
    -- a level (":l", ":r") averages as powers: 0 dB and -20 dB in one block read -2.96 dB (1.01 / 2),
    -- not -10 dB; a gain averages in dB
    local W = LN.new()
    LN.add(W, "w:l", 0, 0.5, 0)
    LN.add(W, "w:l", 0, 0.5, -20)
    LN.add(W, "w:g", 0, 0.5, 0)
    LN.add(W, "w:g", 0, 0.5, -20)
    local lv, gv = LN.here(W, "w:l", 0, 0.5), LN.here(W, "w:g", 0, 0.5)
    check("a level averages as powers, a gain in dB", near(lv, 10 * math.log(1.01 / 2, 10), 1e-6) and near(gv, -10, 1e-9), ("level %.2f dB, gain %.2f dB"):format(lv, gv))
    LN.add(W, "w:l", 1, 1.5, -20)
    lv = LN.here(W, "w:l", 0, 1.5) -- blocks 0 and 2 learned, block 1 takes block 0's
    check("... and so do blocks together", near(lv, 10 * math.log((1.01 / 2 * 2 + 0.01) / 3, 10), 1e-6), ("%.2f dB"):format(lv))
    LN.forget(L, "a:")
    check("a track's FX changed: its keys forgotten", LN.at(L, "a:g", 0, 2) == nil and LN.at(L, "c:g", 0, 0.5) ~= nil, "a: gone, c: kept")
    -- kept between runs: dumped and loaded back the same, a key refused left out
    local D = LN.new()
    local nload = LN.load(D, LN.dump(P), function(key) return key ~= "x:g" end)
    v, s = LN.at(D, "p:g", 10, 12)
    check("dumped and loaded back", nload == 1 and near(v, -4) and s == 1, ("%d key, %.2f dB"):format(nload, v or 0))
    -- the file's text, a key at a time (step 10a): written and read back the same
    local text = LN.key_text(P, "p:g")
    local D3 = LN.new()
    local took = LN.load_text(D3, "p:g", text)
    v, s = LN.at(D3, "p:g", 10, 12)
    check("a key as its file text and back", took and near(v, -4) and s == 1 and LN.key_text(D3, "p:g") == text and LN.key_text(D3, "none") == nil,
      text:sub(1, 40) .. "...")
    LN.add(P, "x:g", 0, 1, 1)
    local D2 = LN.new()
    check("... a key refused stays out", LN.load(D2, LN.dump(P), function(key) return key ~= "x:g" end) == 1 and LN.at(D2, "x:g", 0, 1) == nil, "ok")

    out[#out + 1] = "where a level comes from: { here, elsewhere, never }"
    check("known here through a gain learned elsewhere", same(HD.degrade({ 1, 0, 0 }, { 0, 1, 0 }), { 0, 1, 0 }), vec(HD.degrade({ 1, 0, 0 }, { 0, 1, 0 })))
    -- learned in the same passes, two stages known at the same places: the worse of the two, not
    -- their product (step 9a review: four stages at 75 % gave 32 %)
    check("half here through half here: half", same(HD.degrade({ 0.5, 0.5, 0 }, { 0.5, 0.5, 0 }), { 0.5, 0.5, 0 }), vec(HD.degrade({ 0.5, 0.5, 0 }, { 0.5, 0.5, 0 })))
    local v4 = { 1, 0, 0 }
    for _ = 1, 4 do v4 = HD.degrade(v4, { 0.75, 0.25, 0 }) end
    check("... four stages at 75 %: 75 %", same(v4, { 0.75, 0.25, 0 }), vec(v4))
    check("partly never through partly here", same(HD.degrade({ 0.8, 0.1, 0.1 }, { 0.6, 0.2, 0.2 }), { 0.6, 0.2, 0.2 }), vec(HD.degrade({ 0.8, 0.1, 0.1 }, { 0.6, 0.2, 0.2 })))
    check("anything through a gain never learned", same(HD.degrade({ 1, 0, 0 }, { 0, 0, 1 }), { 0, 0, 1 }), vec(HD.degrade({ 1, 0, 0 }, { 0, 0, 1 })))
    check("an exact gain (no FX) changes nothing", same(HD.degrade({ 0.3, 0.3, 0.4 }, nil), { 0.3, 0.3, 0.4 }), "ok")

    out[#out + 1] = "a bus worked out from its inputs (HD.fill)"
    -- 1 (left) and 2 (right) into bus 3 (FX gain 0.5), 3 and 4 to the master; 5 to the master
    -- with a send (amplitude 0.5) to return 6 (FX gain 0.1)
    local I = { 1, 0, 0, 1 }
    local n = 6
    local dry = { 3, 3, 0, 0, 0, 0 }
    local bus = { [3] = { M = I, fx = true }, [6] = { M = I, fx = true, ret = true }, [0] = { M = I, fx = false } }
    local own = { { 1, 0 }, { 0, 1 }, nil, { 0.5, 0.5 }, { 1, 1 } }
    local sides = { { src = 5, dst = 6, M = { 0.5, 0, 0, 0.5 }, pre = false } }
    local basis = { { 1, 0, 0 }, { 0, 0, 1 }, nil, { 0, 1, 0 }, { 1, 0, 0 } }
    local gain = { [3] = 0.5, [6] = 0.1 }
    -- meas (step 9b review): what the meters measured, carried in the same pass; 1 measured, 2 from
    -- its files, 5 (into the return) not given: not measured
    local meas = { { 1, 0, 0 }, { 0, 1, 0 } }
    local o = { gain = gain, basis = basis, gbasis = { [3] = { 1, 0, 0 }, [6] = { 1, 0, 0 } }, sides = sides, meas = meas }
    HD.fill(n, own, dry, {}, bus, o)
    check("the bus: its inputs x its FX gain", own[3] and near(own[3][1], 0.5) and near(own[3][2], 0.5), ("{%.3f, %.3f}"):format(own[3][1], own[3][2]))
    check("... its basis by its inputs' power", same(basis[3], { 0.5, 0, 0.5 }), vec(basis[3]))
    check("... its share measured, the same way", same(meas[3], { 0.5, 0.5, 0 }), vec(meas[3]))
    check("... a return fed by a part not given: not measured", same(meas[6], { 0, 1, 0 }), vec(meas[6]))
    check("a return: its send x its FX gain", own[6] and near(own[6][1], 0.025) and near(own[6][2], 0.025), ("{%.4f, %.4f}"):format(own[6][1], own[6][2]))
    check("the master: everything on the way to it", own[0] and near(own[0][1], 2.025) and near(own[0][2], 2.025), ("{%.3f, %.3f}"):format(own[0][1], own[0][2]))
    local h = HD.propagate(n, own, dry, {}, bus, { gain = gain, sides = sides })
    check("heard through the bus's learned gain", h[1] and near(h[1][1], 0.5) and near(h[1][2], 0), ("{%.3f, %.3f}"):format(h[1][1], h[1][2]))
    check("... the bus heard as worked out", h[3] and near(h[3][1], 0.5) and near(h[3][2], 0.5), ("{%.3f, %.3f}"):format(h[3][1], h[3][2]))
    local hb = HD.carry_basis(n, basis, dry, { [3] = { 0, 1, 0 } })
    check("a track known here, its bus's gain learned elsewhere", same(hb[1], { 0, 1, 0 }), vec(hb[1]))
    check("... and one whose own FX were never heard", same(hb[2], { 0, 0, 1 }), vec(hb[2]))

    local own2 = { { 1, 0 }, { 0, 1 }, nil, nil, nil, nil }
    local b2 = { { 1, 0, 0 }, { 1, 0, 0 } }
    HD.fill(n, own2, dry, {}, bus, { gain = gain, basis = b2, pass = { false, true, true, true, true, true } })
    check("a muted input is left out", own2[3] and near(own2[3][1], 0) and near(own2[3][2], 0.5), ("{%.3f, %.3f}"):format(own2[3][1], own2[3][2]))
    local own3 = {}
    HD.fill(n, own3, dry, {}, bus, { gain = gain })
    check("nothing playing: no bus output", own3[3] == nil and own3[0] == nil, "nil")

    return bad == 0, table.concat(out, "\n")
  end },
}
