// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 VerkCoding
//
// The 3D stage (roadmap step 8): the stage objects of the engine's graph, drawn where the frames
// say they are heard, with three.js. Built on the reference page the owner liked
// (DESIGN.md "Step 8 research"); the axes are in stage_map.js.
//   - Frames come ten times a second; every part eases towards its newest place, so nothing jumps
//     at the screen's own rate.
//   - A track, a bus measured at its output, and a display group are spheres in the track's
//     colour; a return is a cloud; an open bus or group is a faint shell around what it holds.
//   - A return's width is not known: its files are its sends' (before the reverb or delay, which
//     spreads what it receives), so its cloud gets a nominal breadth, RETURN_DEG each side.
//   - A part cut from the master by a mute (its own or one above it) or a solo elsewhere stays
//     hollow where it was last heard (step 8 review: drawn from its own meter, it was measured
//     against a master that holds only the soloed part, and jumped forward and swelled). One
//     never heard since the page opened is not drawn; the note names it.
//   - Parts more than the "Hide under" threshold below the loudest part are not drawn.
//   - Stopped, the engine works the stage out from the files at the edit cursor (step 9a); each
//     part says how much of its level rests on FX measured there ("model", "FX not known"). An
//     engine from before step 9a leaves the picture as last heard, dimmed.
//   - Labels are measured only when their text changes and moved by a transform: measured every
//     frame, 120 labels cost 15-21 ms a frame (step 8 review), 1 ms without them.

import * as THREE from "./vendor/three/three.module.min.js";
import * as M from "./stage_map.js";

const SECTION = new URLSearchParams(location.search).get("section") || "ReaperForVisual";
const TIMEOUT_MS = 2000;
const $ = (id) => document.getElementById(id);
const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const RETURN_DEG = 20;
const PALETTE = ["#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f", "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac"];

// ---------- the link to REAPER (as the debug page) ----------
function unescapeValue(v) { return v.replace(/\\(\\|n|t)/g, (_, c) => (c === "n" ? "\n" : c === "t" ? "\t" : "\\")); }
async function getKey(key) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  let r;
  try { r = await fetch(`/_/GET/EXTSTATE/${SECTION}/${key}`, { cache: "no-store", signal: ctl.signal }); }
  finally { clearTimeout(timer); }
  const line = (await r.text()).replace(/\n$/, "");
  const parts = line.split("\t");
  const value = parts.length >= 4 ? unescapeValue(parts.slice(3).join("\t")) : "";
  return value ? JSON.parse(value) : null;
}
// commands: "<seq>|<bytes>|<json>", answered in the frame (the web interface cuts long ones)
const queue = [];
let pending = null, lastSent = 0;
function cmd(obj) { queue.push(obj); pump(); }
async function pump() {
  if (pending || !queue.length || !graph) return;
  const c = Object.assign({ tab: graph.tab }, queue.shift());
  const body = JSON.stringify(c);
  const seq = Math.max(Date.now(), lastSent + 1);
  lastSent = seq;
  pending = { seq, c, at: performance.now() };
  try { await fetch(`/_/SET/EXTSTATE/${SECTION}/cmd/${encodeURIComponent(`${seq}|${new TextEncoder().encode(body).length}|${body}`)}`, { cache: "no-store" }); }
  catch (e) { pending = null; say(`could not reach REAPER: ${e}`, "bad"); }
}
function ackFrom(f) {
  if (!pending) return;
  if (f.ack >= pending.seq) { say(f.ack_msg || "", f.ack_ok ? "ok" : "bad"); pending = null; pump(); }
  else if (performance.now() - pending.at > 3000) { say(`no answer from the engine for "${pending.c.op}"`, "bad"); pending = null; pump(); }
}
let sayTimer = null;
function say(text, cls) {
  const el = $("cmdline");
  el.textContent = text; el.className = cls || ""; el.hidden = !text;
  clearTimeout(sayTimer); sayTimer = setTimeout(() => { el.hidden = true; }, 4000);
}
function heartbeat() { fetch(`/_/SET/EXTSTATE/${SECTION}/page_seen/${Date.now()}`, { cache: "no-store" }).catch(() => {}); tellSection(); }
// the section shown, so the engine works it out first (step 9b review): "<ms>|<start>|<end>", or
// "<ms>|" for the stage at the cursor
function tellSection() {
  const x = viewSec && sections && (sections.list || []).find((s) => secKey(s) === viewSec);
  const v = `${Date.now()}|` + (x ? `${x.a}|${x.b}` : "");
  fetch(`/_/SET/EXTSTATE/${SECTION}/page_sect/${encodeURIComponent(v)}`, { cache: "no-store" }).catch(() => {});
}
setInterval(heartbeat, 2000);
setTimeout(heartbeat, 0); // once the sections' state below is set up

// ---------- the scene ----------
const canvas = $("stage");
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 100); // its field of view: resize()
scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 2.7)); // physically based units since r155
const sun = new THREE.DirectionalLight(0xffffff, 1.7); sun.position.set(3, 8, 4); scene.add(sun);
const target = new THREE.Vector3(0, 1.3, -3.2);
const VIEWS = { v3d: { yaw: -0.55, pitch: 0.42, r: 9.5 }, vtop: { yaw: 0, pitch: 1.45, r: 10.5 }, vfront: { yaw: 0, pitch: 0.04, r: 9.0 } };
const cam = Object.assign({}, VIEWS.v3d);
const vec = (p) => new THREE.Vector3(p.x, p.y, p.z);
const at = (az, dist, y) => vec(M.posOf(az, dist, y));

// the distance rings, in dB against the whole mix (step 8 review: unlabelled rings said nothing)
const RINGS_DB = [0, -10, -20, -30];
// the frequency post, at the back right corner of the floor: in view in every preset at 1024 x 768
// (on the left, the side the 3D view looks from, it fell off the screen: step 8 review)
const POST = { az: M.FLOOR_DEG, dist: 6.4 };
const floorGroup = new THREE.Group(); scene.add(floorGroup);
function buildFloor() {
  while (floorGroup.children.length) { const c = floorGroup.children.pop(); if (c.geometry) c.geometry.dispose(); }
  const rule = new THREE.Color(css("--rule")), accent = new THREE.Color(css("--accent")), floorC = new THREE.Color(css("--floor"));
  // the disc's polar angle maps to azimuth as 90° - az once it is laid flat
  const disc = new THREE.Mesh(new THREE.CircleGeometry(6.4, 64, Math.PI / 2 - M.FLOOR_DEG * Math.PI / 180, 2 * M.FLOOR_DEG * Math.PI / 180),
    new THREE.MeshBasicMaterial({ color: floorC, side: THREE.DoubleSide }));
  disc.rotation.x = -Math.PI / 2; floorGroup.add(disc);
  const lineMat = new THREE.LineBasicMaterial({ color: rule });
  for (const d of RINGS_DB.map(M.distOf)) {
    const pts = []; for (let a = -M.FLOOR_DEG; a <= M.FLOOR_DEG; a += 2) pts.push(at(a, d, 0.005));
    floorGroup.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), lineMat));
  }
  for (let a = -M.FLOOR_DEG; a <= M.FLOOR_DEG; a += 10) {
    const m = Math.abs(a) === M.SPEAKER_DEG ? new THREE.LineBasicMaterial({ color: accent }) : lineMat;
    floorGroup.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints([at(a, 0.35, 0.006), at(a, 6.4, 0.006)]), m));
  }
  const post = [at(POST.az, POST.dist, M.BASE), at(POST.az, POST.dist, M.BASE + M.HEIGHT)];
  floorGroup.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(post), lineMat));
  const spMat = new THREE.MeshLambertMaterial({ color: accent });
  for (const s of [-M.SPEAKER_DEG, M.SPEAKER_DEG]) {
    const sp = new THREE.Mesh(new THREE.BoxGeometry(0.34, 0.55, 0.3), spMat); sp.position.copy(at(s, 3.0, 0.4)); sp.lookAt(0, 0.4, 0); floorGroup.add(sp);
  }
  const head = new THREE.Mesh(new THREE.SphereGeometry(0.17, 24, 16), spMat); head.position.set(0, 0.35, 0); floorGroup.add(head);
  const nose = new THREE.Mesh(new THREE.ConeGeometry(0.06, 0.14, 12), spMat); nose.rotation.x = -Math.PI / 2; nose.position.set(0, 0.35, -0.21); floorGroup.add(nose);
}

// ---------- labels ----------
// A label is measured only when its text changes (a size read makes the browser lay the page out
// there and then), stands where a transform puts it, and every write comes after every read.
const labelsEl = $("labels");
function label(cls) {
  const el = document.createElement("div");
  el.className = cls; el.style.display = "none";
  labelsEl.appendChild(el);
  return { el, cls, html: "", w: null, h: null, x: 0, y: 0, want: false, place: false, shown: false, tx: null, ty: null };
}
function setLabel(L, html, cls) {
  if (html !== L.html) { L.el.innerHTML = html; L.html = html; L.w = null; }
  if (cls !== L.cls) { L.el.className = cls; L.cls = cls; }
}
// the guides: the speakers, the listener, the frequency post, the distance rings
const guides = [];
function guide(text, pos) { const L = label("lbl guide"); setLabel(L, esc(text), "lbl guide"); guides.push({ L, pos }); }
guide("L 30°", at(-30, 3.0, 0.85)); guide("R 30°", at(30, 3.0, 0.85)); guide("YOU", new THREE.Vector3(0, 0.75, 0));
for (const hz of [50, 200, 1000, 5000]) guide(hz >= 1000 ? `${hz / 1000} kHz` : `${hz} Hz`, at(POST.az, POST.dist, M.yOf(hz)));
for (const db of RINGS_DB) guide(db === 0 ? "0 dB, the mix" : `−${-db} dB`, at(M.FLOOR_DEG + 4, M.distOf(db), 0.02));

// ---------- the parts ----------
const sphereGeo = new THREE.SphereGeometry(1, 32, 20);
let graph = null, parts = [], loudestRel = 0, stopped = true, modeled = false, lastFrame = null, playingSince = null;
// where each part was, was going, and was last heard, by key, kept across graph changes
const keep = new Map();
const allLabels = () => guides.map((g) => g.L).concat(parts.map((p) => p.L));
let threshold = 40;
try { const v = Number(localStorage.getItem("rfv-stage-floor")); if (v >= 20 && v <= 60) threshold = v; } catch (e) {}

function trackOf(ob) { return graph.tracks[ob.kind === "group" ? (ob.members || [])[0] : ob.track]; }
function keyOf(ob) { return ob.kind === "group" ? `g:${ob.name}` : `${ob.kind}:${graph.tracks[ob.track].guid}`; }
function nameOf(ob) {
  if (ob.kind === "group") return ob.name;
  const t = graph.tracks[ob.track];
  return t.name || `Track ${t.i + 1}`;
}
function buildParts() {
  for (const p of parts) { scene.remove(p.mesh); p.mesh.material.dispose(); p.L.el.remove(); keep.set(p.key, { cur: p.cur, tgt: p.tgt, last: p.last }); }
  parts = [];
  const objs = (graph && graph.stage && graph.stage.objects) || [];
  objs.forEach((ob, j) => {
    const t = trackOf(ob);
    const color = (t && t.color) || PALETTE[j % PALETTE.length];
    const isRet = ob.kind === "return", isBox = !!ob.open;
    const mat = new THREE.MeshLambertMaterial({ color: new THREE.Color(color), transparent: true,
      opacity: isRet ? 0.18 : isBox ? 0.07 : 0.92, depthWrite: !(isRet || isBox) });
    const mesh = new THREE.Mesh(sphereGeo, mat);
    mesh.visible = false;
    scene.add(mesh);
    const base = "lbl" + (isRet ? " ret" : "") + (isBox ? " box" : "");
    const key = keyOf(ob);
    const was = keep.get(key) || {};
    const p = { key, ob, j, isRet, isBox, mesh, L: label(base), base, color, cur: was.cur || null, tgt: was.tgt || null, last: was.last || null, children: [] };
    mesh.userData.p = p;
    parts.push(p);
  });
  for (const p of parts) if (p.ob.parent !== null && p.ob.parent !== undefined && parts[p.ob.parent]) parts[p.ob.parent].children.push(p);
}

// A frame's numbers become each part's target. Stopped, the engine works the stage out from the
// files at the edit cursor (step 9a, f.sm); an engine without that leaves the targets as they
// were (meters are silent), dimmed.
function applyFrame(f) {
  lastFrame = f;
  stopped = (f.play & 1) !== 1;
  if (stopped) playingSince = null; else if (playingSince === null) playingSince = performance.now();
  // a section chosen in the header (step 9b): its average stage stands in for the frame's, worked
  // out as when stopped; until the engine has it, the picture stays
  const sf = sectionFrame(f);
  shownSec = sf ? sf.sec : null;
  if (sf && !sf.f) return;
  if (sf) f = sf.f;
  modeled = !!sf || (stopped && f.sm === 1);
  // a frame for another graph than the one read (a newer graph came in between): wait for its own
  if ((stopped && !modeled) || !graph || f.gseq !== graph.gseq || !f.o || f.o.length !== parts.length) return;
  const ae = new Set(f.ae || []), ha = new Set(f.ha || []), hi = new Set(f.hi || []), mu = new Set(f.mu || []), oc = new Set(f.oc || []);
  const mixZ = f.ma && f.ma[1] !== null ? f.ma[1] : null;
  let loudestZ = null;
  for (const v of f.o) if (v && v[1] !== null && (loudestZ === null || v[1] > loudestZ)) loudestZ = v[1];
  for (const p of parts) {
    const v = f.o[p.j], y = f.oy && f.oy[p.j], tr = p.ob.track;
    if (!v || v[1] === null) {
      // cut by a mute or a solo: hollow where it was last heard; else silent now, not drawn
      p.tgt = oc.has(p.j) && p.last ? Object.assign({}, p.last, { ghost: true, muted: tr !== null && mu.has(tr) }) : null;
      continue;
    }
    // Y: none yet for a moment after the stage changed or the engine started (the last one
    // stays); while its files are still read, the last Y it had stays until there is one
    const last = p.last;
    let hz, corr, unknown, unseen, read;
    if (y) [hz, corr, unknown, unseen, read] = y;
    else if (last) ({ hz, corr, unknown, unseen, read } = last);
    else [hz, corr, unknown, unseen, read] = [null, null, 0, 0, 0];
    if (hz === null && read < 0.5 && last && last.hz !== null) hz = last.hz;
    p.tgt = { az: v[0] === null ? 0 : v[0], z: v[1], rel: M.relOf(v[1], mixZ, loudestZ), ghost: false, muted: false,
      hz, corr: corr !== null && !p.isRet ? corr : null, unknown, unseen, read,
      est: tr !== null && ae.has(tr), approx: tr !== null && ha.has(tr), gap: tr !== null && hi.has(tr),
      // stopped: the shares of its level measured here when played, learned elsewhere, never
      basis: modeled && f.ob ? f.ob[p.j] || null : null };
    p.last = p.tgt;
  }
  // no Y of its own (a virtual instrument): its container's, marked "?"; else the middle
  for (const p of parts) {
    if (!p.tgt) continue;
    p.tgt.yGuess = p.tgt.hz === null;
    if (p.tgt.hz === null) {
      const up = p.ob.parent !== null && p.ob.parent !== undefined ? parts[p.ob.parent] : null;
      p.tgt.hzDraw = up && up.tgt && up.tgt.hz !== null ? up.tgt.hz : 500;
    } else p.tgt.hzDraw = p.tgt.hz;
  }
  loudestRel = -Infinity;
  for (const p of parts) if (p.tgt && !p.tgt.ghost && !p.isBox) loudestRel = Math.max(loudestRel, p.tgt.rel);
  if (loudestRel === -Infinity) loudestRel = 0;
  // stopped: where the stage's levels come from, by power, and the state most of it is in (the
  // note says it; a part's own mark only where it differs, step 9a: a mark on every label hid names)
  basisShares = null; stageCat = null;
  if (modeled) {
    const s = [0, 0, 0], byCat = {};
    for (const p of parts) {
      const t = p.tgt;
      if (!t || t.ghost || !t.basis || p.isBox) continue;
      const x = Math.pow(10, t.rel / 10);
      for (let i = 0; i < 3; i++) s[i] += x * t.basis[i];
      byCat[catOf(t.basis)] = (byCat[catOf(t.basis)] || 0) + x;
    }
    const w = s[0] + s[1] + s[2];
    if (w > 0) {
      basisShares = s.map((v) => v / w);
      stageCat = Object.keys(byCat).sort((a, b) => byCat[b] - byCat[a])[0];
    }
  }
}
let basisShares = null, stageCat = null;

// ---------- sections (step 9b) ----------
// The engine's "sections" key: { gseq, source, used, list: [{ name, a, b, played, ma, o, oy, ob,
// nl }] }, the stage fields once worked out. The page shows the stage at the cursor, or one
// section's average stage chosen in the header (by name and times, so a list worked out again
// keeps the choice).
let sections = null, viewSec = "", shownSec = null, sectSig = "";
const secKey = (x) => `${x.name}|${x.a}|${x.b}`;
function sectionFrame(f) {
  if (!viewSec || !sections) return null;
  const sec = (sections.list || []).find((x) => secKey(x) === viewSec);
  if (!sec) return null;
  if (!sec.o || !graph || sections.gseq !== graph.gseq) return { sec, f: null };
  return { sec, f: Object.assign({}, f, { o: sec.o, oy: sec.oy, ob: sec.ob, ma: sec.ma, nl: sec.nl || [], sm: 1, oc: [], ae: [], hi: [], gseq: sections.gseq }) };
}
function updateSections() {
  const group = $("sectgroup"), sel = $("sect");
  group.hidden = !sections;
  if (!sections) return;
  const list = sections.list || [];
  const sig = list.map((x) => `${secKey(x)}|${x.played === undefined ? "" : Math.round(100 * x.played)}`).join("\n");
  if (sig !== sectSig) {
    sectSig = sig;
    while (sel.options.length > 1) sel.remove(1);
    for (const x of list) {
      const o = document.createElement("option");
      o.value = secKey(x);
      o.textContent = `${x.name} · ${fmtSpan(x)}` + (x.played === undefined ? "" : ` · ${Math.round(100 * x.played)} % measured`);
      sel.appendChild(o);
    }
    if (viewSec && !list.some((x) => secKey(x) === viewSec)) viewSec = ""; // that section is gone
    sel.value = viewSec;
  }
  const src = (graph && graph.view && graph.view.sections && graph.view.sections.source) || sections.source || "regions";
  if ($("sectsrc").value !== src) $("sectsrc").value = src;
}
// a part's level, stopped: measured here, a model (its FX measured elsewhere), or its FX not heard
function catOf(b) { return b[2] >= 0.5 ? "never" : b[0] >= 0.9 ? "here" : "model"; }

function marks(p) {
  const t = p.tgt, m = [];
  if (!t) return m;
  if (t.muted) m.push(["muted", "muted: drawn where it was last heard, not heard now"]);
  else if (t.ghost) m.push(["silenced", "cut by a mute above it or a solo elsewhere: drawn where it was last heard, not heard now"]);
  // "?" only once its files are read: before that, nothing is known either way (step 8 review)
  const reading = !t.ghost && t.read < 0.5;
  if (t.ghost || reading) { /* its Y is the last heard, or still being read */ }
  else if (t.yGuess || t.unknown >= 0.5) m.push(["?", "its sound does not come from files (a virtual instrument, a live input): no Y of its own"]);
  else if (t.unknown >= 0.1) m.push([`${Math.round(100 * t.unknown)} % ?`, `${Math.round(100 * t.unknown)} % of its power has no Y`]);
  if (p.isRet) m.push(["≈", "a return: its Y comes from what its sends bring it, before its reverb or delay; its width is not known"]);
  if (t.corr !== null && t.corr < 0) m.push(["anti-phase", "its left and right are out of phase: heard wider than the speakers, and they cancel in mono"]);
  if (t.est) m.push(["est.", "a live input: estimated through its own pan and fader, FX ignored"]);
  if (t.approx) m.push(["approx.", "its way to the master takes a send before the FX: the FX are not counted"]);
  if (t.gap) m.push(["image gap", "this bus's FX move or widen its image: its tracks' heard X is off"]);
  // stopped (step 9a): how much of its level rests on FX heard here, elsewhere, or never; marked
  // only where it differs from most of the stage (the note says that)
  const b = !t.ghost && t.basis;
  const cat = b && catOf(b);
  if (cat && cat !== stageCat) {
    if (cat === "never") m.push(["FX?", "stopped, this place has not played: its level comes from its files through its fader and pan, and its FX have not been heard yet, so what they add or take is not in it: play this part once"]);
    else if (cat === "model") m.push(["model", `stopped: ${Math.round(100 * b[0])} % as measured here when it played, ${Math.round(100 * b[1])} % from its files with its FX as measured elsewhere in the song${b[2] >= 0.05 ? `, ${Math.round(100 * b[2])} % with FX not heard yet` : ""}`]);
    else m.push(["measured", "stopped: as its meter measured it here when it played (or from its files, where it has no FX), through its fader and pan as they are now"]);
  }
  if (reading) m.push(["reading", shownSec
    ? "its files in this section are still being read: its Y is still settling"
    : `only ${Math.round(100 * t.read)} % of the files it rests on around the play position are read yet: its Y is still settling`]);
  return m;
}

// ---------- each screen frame ----------
let last = performance.now(), selected = null, hiddenShown = 0;
const times = [], works = []; // the last screen frames: the time between them, and the work in each (ms)
function update(dt) {
  const k = (cur, tgt) => M.ease(cur, tgt, dt);
  for (const p of parts) {
    const t = p.tgt;
    if (!t) { p.mesh.visible = false; p.show = false; continue; }
    const dist = M.distOf(t.rel), r = M.radOf(t.rel), y = M.yOf(t.hzDraw);
    const across = p.isRet ? M.acrossOf(RETURN_DEG, dist, r * 1.6) : M.acrossOf(M.widthDeg(t.corr), dist, r);
    if (!p.cur) p.cur = { az: t.az, dist, y, r, across };
    const c = p.cur;
    c.az = k(c.az, t.az); c.dist = k(c.dist, dist); c.y = k(c.y, y); c.r = k(c.r, r); c.across = k(c.across, across);
    p.show = !p.isBox && !M.belowFloor(t.rel, loudestRel, threshold);
    if (p.isBox) continue;
    p.mesh.visible = p.show;
    p.mesh.position.copy(at(c.az, c.dist, c.y));
    p.mesh.scale.set(c.across, p.isRet ? c.r * 1.4 : c.r, p.isRet ? c.r * 1.3 : c.r);
    p.mesh.rotation.set(0, -c.az * Math.PI / 180, 0);
    const mat = p.mesh.material;
    // a hollow sphere when cut; a cut return only fainter (a wire cloud that size hid the stage)
    mat.wireframe = t.ghost && !p.isRet;
    mat.opacity = (p.isRet ? (t.ghost ? 0.07 : 0.18) : t.ghost ? 0.35 : 0.92) * (stopped && !modeled ? 0.45 : 1);
  }
  // how many parts the "Hide under" threshold keeps off the stage now
  const hidden = parts.filter((p) => p.tgt && !p.isBox && !p.show).length;
  if (hidden !== hiddenShown) { $("floorn").textContent = hidden ? `(${hidden} hidden)` : ""; hiddenShown = hidden; }
  // an open bus or group: a faint shell around the parts it holds that are drawn
  for (const p of parts) {
    if (!p.isBox) continue;
    const kids = p.children.filter((q) => q.show && q.mesh.visible);
    if (!kids.length) { p.mesh.visible = false; p.show = false; continue; }
    const centre = new THREE.Vector3();
    for (const q of kids) centre.add(q.mesh.position);
    centre.multiplyScalar(1 / kids.length);
    let rad = 0;
    for (const q of kids) rad = Math.max(rad, q.mesh.position.distanceTo(centre) + Math.max(q.mesh.scale.x, q.mesh.scale.y));
    p.mesh.position.copy(centre); p.mesh.scale.setScalar(rad + 0.15); p.mesh.rotation.set(0, 0, 0);
    p.mesh.material.opacity = 0.07 * (stopped && !modeled ? 0.45 : 1);
    p.mesh.visible = true; p.show = true;
  }
}

const tmp = new THREE.Vector3(), top = new THREE.Vector3();
function onScreen(v) { // where v falls on the screen, or null behind the camera (or no screen)
  if (!canvas.clientWidth || !canvas.clientHeight) return null;
  tmp.copy(v).project(camera);
  if (tmp.z > 1) return null;
  return { x: (tmp.x + 1) / 2 * canvas.clientWidth, y: (1 - tmp.y) / 2 * canvas.clientHeight };
}
const overlaps = (r, list) => list.some((q) => r.x0 < q.x1 + 2 && r.x1 > q.x0 - 2 && r.y0 < q.y1 + 1 && r.y1 > q.y0 - 1);
function rank(p) { // the selected part first, then louder parts; clouds, shells and silenced parts last
  if (p === selected) return 1e9;
  const t = p.tgt;
  return (p.isRet || p.isBox ? -100 : 0) + (t && t.ghost ? -50 : 0) + (t ? t.rel : -999);
}
function labels() {
  // what each label says and where it would stand: the parts first, the guides where room is left
  // (a guide placed first took the name of a part standing by a speaker)
  const want = [];
  for (const p of parts.slice().sort((a, b) => rank(b) - rank(a))) {
    const L = p.L;
    L.want = false;
    if (!p.show) continue;
    const html = p.isBox ? `${esc(nameOf(p.ob))} <span class="mk">${p.ob.kind === "group" ? "group" : "bus"}</span>`
      : esc(nameOf(p.ob)) + marks(p).map(([m]) => `<span class="mk">${esc(m)}</span>`).join("");
    setLabel(L, html, p.base + (p.tgt && p.tgt.ghost ? " ghost" : "") + (p === selected ? " sel" : ""));
    top.copy(p.mesh.position); top.y += p.mesh.scale.y + 0.05;
    const s = onScreen(top);
    if (s) { L.want = true; L.x = s.x; L.y = s.y; want.push(L); }
  }
  for (const g of guides) {
    const s = onScreen(g.pos);
    g.L.want = !!s;
    if (s) { g.L.x = s.x; g.L.y = s.y; want.push(g.L); }
  }
  // measure the new texts, all in one go (a label needs to be displayed to have a size)
  const fresh = want.filter((L) => L.w === null);
  for (const L of fresh) if (!L.shown) { L.el.style.display = ""; L.shown = true; }
  for (const L of fresh) { L.w = L.el.offsetWidth; L.h = L.el.offsetHeight; }
  // keep each one that does not overlap one kept before it
  const placed = [];
  for (const L of want) {
    const r = { x0: L.x - L.w / 2, x1: L.x + L.w / 2, y0: L.y - L.h, y1: L.y };
    L.place = !overlaps(r, placed);
    if (L.place) placed.push(r);
  }
  // and write: centred above its point
  for (const L of allLabels()) {
    const on = L.want && L.place;
    if (on) {
      const tx = Math.round(L.x - L.w / 2), ty = Math.round(L.y - L.h);
      if (tx !== L.tx || ty !== L.ty) { L.el.style.transform = `translate(${tx}px, ${ty}px)`; L.tx = tx; L.ty = ty; }
    }
    if (on !== L.shown) { L.el.style.display = on ? "" : "none"; L.shown = on; }
  }
}
if (document.fonts) document.fonts.ready.then(() => { for (const L of allLabels()) L.w = null; });
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

// The view is 42 degrees high on a 4:3 screen or wider; on a narrower one (a phone held upright)
// it keeps that width instead, else the speakers, the listener and the guides fall off the sides.
const FOV = 42, FOV_ASPECT = 4 / 3;
function resize() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.floor(w * renderer.getPixelRatio()) || canvas.height !== Math.floor(h * renderer.getPixelRatio())) {
    renderer.setSize(w, h, false); camera.aspect = w / Math.max(h, 1);
    camera.fov = camera.aspect >= FOV_ASPECT ? FOV
      : 2 * Math.atan(Math.tan(FOV * Math.PI / 360) * FOV_ASPECT / camera.aspect) * 180 / Math.PI;
    camera.updateProjectionMatrix();
  }
}
function placeCamera() {
  const cp = Math.cos(cam.pitch), sp = Math.sin(cam.pitch);
  camera.position.set(target.x + cam.r * cp * Math.sin(cam.yaw), target.y + cam.r * sp, target.z + cam.r * cp * Math.cos(cam.yaw));
  camera.lookAt(target);
}
function animate(now) {
  const w0 = performance.now();
  const dt = Math.min(0.1, (now - last) / 1000);
  times.push(now - last); if (times.length > 600) times.shift();
  last = now;
  resize(); placeCamera(); update(dt);
  renderer.render(scene, camera);
  labels();
  works.push(performance.now() - w0); if (works.length > 600) works.shift();
  requestAnimationFrame(animate);
}

// ---------- detail, camera, controls ----------
const fmtAz = (az) => Math.abs(az) < 0.5 ? "centre" : `${Math.abs(az).toFixed(1)}° ${az < 0 ? "L" : "R"}`;
const fmtHz = (hz) => hz >= 1000 ? `${(hz / 1000).toFixed(2)} kHz` : `${Math.round(hz)} Hz`;
function fmtTime(s) { const m = Math.floor(s / 60), r = s - 60 * m; return `${m}:${r < 10 ? "0" : ""}${r.toFixed(1)}`; }
// a section's times to the second (step 9b review: "0:22.0–0:40.0" read as more exact than a
// region's edges are)
function fmtSec(s) { const t = Math.round(s), m = Math.floor(t / 60), r = t - 60 * m; return `${m}:${r < 10 ? "0" : ""}${r}`; }
const fmtSpan = (x) => `${fmtSec(x.a)}–${fmtSec(x.b)}`;
function showDetail(p) {
  const el = $("detail");
  if (!p || !p.tgt) {
    el.innerHTML = `<span class="muted">Hover or tap a part to read where it is heard, how wide, how loud in the mix and its spectral centre.</span>`;
    return;
  }
  const t = p.tgt;
  const kind = p.isBox ? (p.ob.kind === "group" ? `group of ${(p.ob.members || []).length}, open` : "bus, open")
    : p.ob.kind === "group" ? `group of ${(p.ob.members || []).length}` : p.ob.kind === "bus" ? "bus, measured at its output" : p.ob.kind;
  const w = M.widthPct(t.corr);
  el.innerHTML = `<div class="nm">${esc(nameOf(p.ob))}</div><dl>
    <dt>Kind</dt><dd>${esc(kind)}</dd>
    <dt>Heard at</dt><dd>${fmtAz(t.az)}${t.ghost ? " (when last heard)" : ""}</dd>
    <dt>Width</dt><dd>${p.isRet ? "not known (after its reverb or delay)" : w === null ? "-" : `${w} %`}</dd>
    <dt>Level</dt><dd>${t.rel >= 0 ? "+" : ""}${t.rel.toFixed(1)} dB against the whole mix (${t.z.toFixed(1)} dB)${t.ghost ? ", when last heard" : ""}</dd>
    <dt>Spectral centre</dt><dd>${t.hz === null ? "? (no files)" : fmtHz(t.hz)}</dd>` +
    (t.basis ? `<dt>Level from</dt><dd>${Math.round(100 * t.basis[0])} % measured here, ${Math.round(100 * t.basis[1])} % its files with FX measured elsewhere, ${Math.round(100 * t.basis[2])} % FX not heard yet</dd>` : "") +
    `</dl>` +
    marks(p).map(([m, why]) => `<div class="why">${esc(m)}: ${esc(why)}</div>`).join("");
}
const ray = new THREE.Raycaster(), mouse = new THREE.Vector2();
function pick(e, sticky) {
  const rc = canvas.getBoundingClientRect();
  mouse.set(((e.clientX - rc.left) / rc.width) * 2 - 1, -((e.clientY - rc.top) / rc.height) * 2 + 1);
  ray.setFromCamera(mouse, camera);
  const hits = ray.intersectObjects(parts.filter((p) => p.mesh.visible).map((p) => p.mesh));
  const solid = hits.find((h) => !h.object.userData.p.isRet && !h.object.userData.p.isBox) || hits[0];
  const p = solid ? solid.object.userData.p : null;
  if (sticky) selected = p;
  showDetail(p || selected);
}
function setView(id) {
  for (const k of Object.keys(VIEWS)) $(k).setAttribute("aria-pressed", String(k === id));
  if (id) Object.assign(cam, VIEWS[id]);
}
for (const k of Object.keys(VIEWS)) $(k).addEventListener("click", () => setView(k));
let drag = null;
const pointers = new Map();
canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId); pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  drag = { x: e.clientX, y: e.clientY, yaw: cam.yaw, pitch: cam.pitch, moved: false };
});
canvas.addEventListener("pointermove", (e) => {
  if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()]; const d = Math.hypot(a.x - b.x, a.y - b.y);
    if (drag && drag.pinch) cam.r = Math.max(4, Math.min(18, drag.r0 * drag.pinch / d)); else drag = { pinch: d, r0: cam.r };
    setView(null); return;
  }
  if (drag && !drag.pinch) {
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) { drag.moved = true; setView(null); }
    if (drag.moved) { cam.yaw = drag.yaw - dx * 0.008; cam.pitch = Math.max(0.02, Math.min(1.5, drag.pitch + dy * 0.006)); }
  } else if (e.pointerType === "mouse") pick(e, false);
});
const endPointer = (e) => { pointers.delete(e.pointerId); if (drag && !drag.moved && !drag.pinch) pick(e, true); if (!pointers.size) drag = null; };
canvas.addEventListener("pointerup", endPointer);
canvas.addEventListener("pointercancel", endPointer);
canvas.addEventListener("wheel", (e) => { e.preventDefault(); cam.r = Math.max(4, Math.min(18, cam.r * (1 + Math.sign(e.deltaY) * 0.08))); setView(null); }, { passive: false });

$("floor").value = String(threshold);
$("floorv").textContent = `${threshold} dB`;
$("floor").addEventListener("input", (e) => {
  threshold = Number(e.target.value); $("floorv").textContent = `${threshold} dB`;
  try { localStorage.setItem("rfv-stage-floor", String(threshold)); } catch (err) {}
});
$("mode").addEventListener("click", () => cmd({ op: "mode", m: "toggle" }));
$("startall").addEventListener("click", () => cmd({ op: "mode", m: "all" }));
$("startsel").addEventListener("click", () => cmd({ op: "take", how: "show" }));
$("sect").addEventListener("change", (e) => { viewSec = e.target.value; tellSection(); if (lastFrame) { applyFrame(lastFrame); note(); } });
$("sectsrc").addEventListener("change", (e) => cmd({ op: "sections", source: e.target.value }));
$("undo").addEventListener("click", () => cmd({ op: "undo" }));
$("redo").addEventListener("click", () => cmd({ op: "redo" }));
$("aboutbtn").addEventListener("click", () => {
  const a = $("about"); a.hidden = !a.hidden; $("aboutbtn").setAttribute("aria-expanded", String(!a.hidden));
});
$("debug").href = `debug.html${location.search}`;
// the panels under the header stand below it, however many rows it wraps to
const head = document.querySelector("header");
new ResizeObserver(() => document.documentElement.style.setProperty("--head", `${head.offsetHeight}px`)).observe(head);

function note() {
  const el = $("note");
  let text = "";
  const objs = (graph && graph.stage && graph.stage.objects) || [];
  // drawn: anything heard in this project since the page opened (not in another tab's)
  const drawn = parts.some((p) => p.tgt);
  const chosenSec = viewSec && sections && (sections.list || []).find((x) => secKey(x) === viewSec);
  // a project never set up: the getting-started card instead of a line of text (step 11)
  const fresh = !!(graph && graph.stage && graph.stage.mode === "chosen" && !objs.length);
  $("start").hidden = !fresh;
  if (fresh) {
    text = "";
  } else if (chosenSec) {
    // a section's average stage (step 9b)
    const head = `Section ${chosenSec.name} (${fmtSpan(chosenSec)})`;
    const pl = chosenSec.played;
    if (!shownSec || pl === undefined) text = `${head}: working out its average stage…`;
    else if (pl >= 0.9) text = `${head}: its average stage as measured when it played, through the faders and pans as they are now.`;
    else if (pl < 0.1) text = `${head}: not played yet, so its average stage comes from the files through the faders and pans as they are now, with the FX as measured elsewhere in the song, or not heard yet.`;
    else text = `${head}: its average stage, ${Math.round(100 * pl)} % as measured when it played, the rest from the files, through the faders and pans as they are now.`;
    // the files it rests on still being read (the first minutes after a start: step 9b review);
    // measured where it played, only heights and widths rest on them
    if (shownSec && pl !== undefined && chosenSec.read !== undefined && chosenSec.read < 0.99)
      text += ` Its files are ${Math.round(100 * chosenSec.read)} % read: ` +
        (pl >= 0.9 ? "heights and widths may still move." : "parts may still be missing, and levels and heights may still move.");
    // muted or cut by a solo now: not in its stage, as nothing of them is heard (step 9b review)
    const mu = new Set(lastFrame && lastFrame.mu || []), oc = new Set(lastFrame && lastFrame.oc || []);
    const cut = parts.filter((p) => !p.isBox && oc.has(p.j)).map((p) => nameOf(p.ob) + (p.ob.track !== null && mu.has(p.ob.track) ? " (muted)" : ""));
    if (shownSec && cut.length) text += ` Left out, muted or cut by a solo now: ${cut.slice(0, 4).join(", ")}${cut.length > 4 ? ` and ${cut.length - 4} more` : ""}.`;
    if (!stopped) text += " The song is playing: \"At the cursor\" shows it live.";
  } else if (lastFrame && modeled && objs.length) {
    // stopped at the edit cursor (step 9a and its review): how much of the stage was measured here
    // when it played, by the parts' power
    // the share its meters measured here (f.mp; the basis counts a part with no FX as exact from
    // its files, not measured: step 9b review); an engine from before has only the basis
    const at = fmtTime(lastFrame.pos), s = basisShares;
    const m = typeof lastFrame.mp === "number" ? lastFrame.mp : s ? s[0] : 0;
    const tail = "through the faders and pans as they are now";
    const fxElse = s && s[1] >= 0.1; // some of it rests on FX measured elsewhere in the song
    if (!drawn) text = `Stopped at ${at}: reading the files there.`;
    else if (m >= 0.9) text = `Stopped at ${at}: the stage as measured here when it played, ${tail}.`;
    else if (!s || s[2] >= 0.5) text = `Stopped at ${at}: the stage from the files at the cursor ${tail}. Most FX have not been heard yet: play the song once and their effect is measured.`;
    else if (m < 0.1) text = `Stopped at ${at}: the stage from the files at the cursor ${tail}${fxElse ? ", with the FX as measured elsewhere in the song" : ""}: this place has not played yet.`;
    else text = `Stopped at ${at}: ${Math.round(100 * m)} % of the stage as measured here when it played, the rest from the files${fxElse ? " with the FX measured elsewhere" : ""}, ${tail}.`;
    // a virtual instrument with MIDI here that never sounded since the engine started
    const nl = new Set(lastFrame.nl || []);
    const none = parts.filter((p) => nl.has(p.j)).map((p) => nameOf(p.ob));
    if (none.length) text += ` Not drawn: ${none.join(", ")} (a virtual instrument not heard yet).`;
    // the files there still being read (the first minutes after a start): parts come in one by one
    const ym = lastFrame.ym;
    if (drawn && ym && ym.now < 0.99) text += ` The files around the cursor are ${Math.round(100 * ym.now)} % read.`;
  } else if (lastFrame && stopped && !drawn && objs.length) {
    text = "Press play in REAPER: where each part is heard comes from its meters while playing.";
  } else if (lastFrame && stopped && objs.length) {
    text = "Stopped: the stage as last heard (dimmed).";
  } else if (lastFrame && !stopped && playingSince !== null && performance.now() - playingSince > 3000) {
    // a part never heard since the page opened is not drawn: say so, rather than leave it out
    // without a word (step 8 review); muted or cut ones are told apart
    const mu = new Set(lastFrame.mu || []), oc = new Set(lastFrame.oc || []);
    const unheard = parts.filter((p) => !p.isBox && !p.tgt && !p.last).map((p) =>
      nameOf(p.ob) + (p.ob.track !== null && mu.has(p.ob.track) ? " (muted)" : oc.has(p.j) ? " (silenced)" : ""));
    if (unheard.length) {
      const shown = unheard.slice(0, 4).join(", ") + (unheard.length > 4 ? ` and ${unheard.length - 4} more` : "");
      text = `Not drawn, not heard since this page opened: ${shown}.`;
    }
  }
  if (text !== el.textContent) el.textContent = text;
  el.hidden = !text;
}

// ---------- polling ----------
let lastSeq = -1, lastSeqAt = 0, idle = false, sectAt = 0;
function renderState(f) {
  const stale = performance.now() - lastSeqAt > 1500;
  const st = f.state === "stopped" ? "stopped" : stale ? "paused" : "running";
  $("state").className = `state ${st}`;
  $("state").textContent = f.state === "stopped" ? "engine stopped" : stale ? "paused (REAPER busy?)" : "running";
}
async function poll() {
  const started = performance.now();
  if (!document.hidden) {
    try {
      const f = await getKey("frame");
      if (!f) {
        idle = true;
        $("state").className = "state waiting"; $("state").textContent = "not started: run \"ReaperForVisual - Start or stop\" in REAPER";
      } else {
        if (f.seq < lastSeq) graph = null; // a new engine counts from 0
        if (f.seq !== lastSeq) { lastSeq = f.seq; lastSeqAt = performance.now(); }
        if (!graph || graph.gseq !== f.gseq) {
          graph = await getKey("graph");
          if (graph) {
            buildParts();
            $("project").textContent = `${graph.name || "unsaved project"} · ${graph.stage ? graph.stage.objects.length : 0} on the stage`;
            $("version").textContent = graph.version || "";
            $("mode").setAttribute("aria-pressed", String(graph.stage && graph.stage.mode === "all"));
            const h = graph.history || { undo: 0, redo: 0 };
            $("undo").disabled = !h.undo; $("redo").disabled = !h.redo;
          }
        }
        // the sections, once a second, twice while one is shown (step 9b; an engine from before
        // has none)
        if (performance.now() - (sectAt || 0) >= (viewSec ? 500 : 1000)) {
          sectAt = performance.now();
          try { sections = await getKey("sections"); } catch (e) { sections = null; }
          if (sections && graph && sections.tab !== graph.tab) sections = null; // another tab's
          updateSections();
        }
        applyFrame(f);
        renderState(f);
        ackFrom(f);
        pump();
        note();
        if (selected) showDetail(selected);
        idle = f.state === "stopped";
      }
    } catch (e) {
      idle = true;
      $("state").className = "state unreachable"; $("state").textContent = "REAPER's web interface is not answering";
    }
  }
  setTimeout(poll, Math.max(0, (document.hidden || idle ? 1000 : 100) - (performance.now() - started)));
}

// for tests and debugging: what is drawn, and how smoothly
window.rfvStage = {
  parts: () => parts.map((p) => ({ name: graph ? nameOf(p.ob) : "", kind: p.ob.kind, open: !!p.ob.open, shown: !!p.show, label: p.L.shown,
    target: p.tgt ? { az: p.tgt.az, rel: p.tgt.rel, z: p.tgt.z, hz: p.tgt.hz, corr: p.tgt.corr, ghost: p.tgt.ghost, muted: p.tgt.muted, read: p.tgt.read, basis: p.tgt.basis } : null,
    drawn: p.cur ? { az: p.cur.az, dist: p.cur.dist, y: p.cur.y, r: p.cur.r } : null, marks: marks(p).map(([m]) => m) })),
  // the guides' labels: shown, and where (left and top edges, size)
  guides: () => guides.map((g) => ({ text: g.L.el.textContent, shown: g.L.shown, x: g.L.tx, y: g.L.ty, w: g.L.w, h: g.L.h })),
  // between: the time from one screen frame to the next (the browser may slow it when the page is
  // in the background); work: what each frame cost the page (update, render, labels)
  frames: () => {
    const stat = (v) => {
      const s = v.slice().sort((a, b) => a - b);
      const q = (x) => s.length ? +s[Math.min(s.length - 1, Math.floor(s.length * x))].toFixed(2) : 0;
      return { n: s.length, median: q(0.5), p95: q(0.95), p99: q(0.99), max: s.length ? +s[s.length - 1].toFixed(2) : 0 };
    };
    return { between: stat(times), work: stat(works) };
  },
  threshold: () => threshold, loudestRel: () => loudestRel, stopped: () => stopped, modeled: () => modeled,
  // the sections as the engine lists them, and the one shown (null: the stage at the cursor)
  sections: () => sections, section: () => shownSec && shownSec.name,
  chooseSection: (name) => { const x = (sections && sections.list || []).find((s) => s.name === name); viewSec = x ? secKey(x) : ""; $("sect").value = viewSec; tellSection(); if (lastFrame) applyFrame(lastFrame); note(); return !!x; },
  // n screen frames' work in a row, timed, whatever the browser's frame rate (a hidden or
  // background page gets few or no frames, which says nothing about the page's own cost); the
  // camera turns a little each frame, so every label moves, as while the user turns the view
  bench: (n = 120) => {
    const w = [], yaw = cam.yaw;
    for (let i = 0; i < n; i++) {
      const w0 = performance.now();
      cam.yaw = yaw + 0.004 * (i % 50);
      resize(); placeCamera(); update(1 / 60); renderer.render(scene, camera); labels();
      w.push(performance.now() - w0);
    }
    cam.yaw = yaw;
    w.sort((a, b) => a - b);
    const q = (x) => +w[Math.min(w.length - 1, Math.floor(w.length * x))].toFixed(2);
    return { n, median: q(0.5), p95: q(0.95), max: +w[w.length - 1].toFixed(2), shown: parts.filter((p) => p.show).length, labels: labelsEl.querySelectorAll(".lbl:not([style*='display: none'])").length };
  },
};

buildFloor();
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", buildFloor);
showDetail(null);
requestAnimationFrame((t) => { last = t; animate(t); });
poll();
