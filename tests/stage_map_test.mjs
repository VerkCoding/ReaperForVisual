// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 VerkCoding
//
// Step 8, method: web/stage_map.js, the stage's axes, without a browser.
//   node tests/stage_map_test.mjs
import * as M from "../web/stage_map.js";

let bad = 0;
const near = (a, b, tol = 1e-9) => Math.abs(a - b) <= tol;
function check(what, ok, detail) {
  if (!ok) bad++;
  console.log(`  ${what.padEnd(58)} ${detail}${ok ? "" : "   <-- FAIL"}`);
}

console.log("height (Y): log scale, 40 Hz at the floor, 12 kHz at the top");
check("40 Hz", near(M.yOf(40), M.BASE), M.yOf(40).toFixed(3));
check("12 kHz", near(M.yOf(12000), M.BASE + M.HEIGHT), M.yOf(12000).toFixed(3));
const mid = Math.sqrt(40 * 12000);
check("their geometric mean halfway", near(M.yOf(mid), M.BASE + M.HEIGHT / 2, 1e-12), M.yOf(mid).toFixed(3));
check("below 40 Hz and above 12 kHz held at the ends", near(M.yOf(10), M.BASE) && near(M.yOf(20000), M.BASE + M.HEIGHT), "ok");

console.log("distance and size (Z): level against the whole mix, over 30 dB");
check("as loud as the mix: nearest", near(M.distOf(0), M.NEAR), M.distOf(0).toFixed(2));
check("30 dB under: farthest", near(M.distOf(-30), M.NEAR + M.DEPTH), M.distOf(-30).toFixed(2));
check("60 dB under: still farthest", near(M.distOf(-60), M.NEAR + M.DEPTH), M.distOf(-60).toFixed(2));
check("louder is nearer and bigger", M.distOf(-6) < M.distOf(-12) && M.radOf(-6) > M.radOf(-12), `${M.distOf(-6).toFixed(2)} < ${M.distOf(-12).toFixed(2)}`);
check("relative to the mix", near(M.relOf(-20, -8, -10), -12), String(M.relOf(-20, -8, -10)));
check("no mix level: relative to the loudest part", near(M.relOf(-20, null, -10), -10), String(M.relOf(-20, null, -10)));
check("40 dB under the loudest: off the stage", M.belowFloor(-45, -4, 40) && !M.belowFloor(-43, -4, 40), "ok");

console.log("width: 30 degrees x (1 - correlation)");
check("one point (correlation 1)", near(M.widthDeg(1), 0) && M.widthPct(1) === 0, `${M.widthDeg(1)} deg, ${M.widthPct(1)} %`);
check("unrelated channels: speaker to speaker", near(M.widthDeg(0), 30) && M.widthPct(0) === 100, `${M.widthDeg(0)} deg, ${M.widthPct(0)} %`);
check("out of phase: past the speakers", near(M.widthDeg(-1), 60) && M.widthPct(-1) === 200, `${M.widthDeg(-1)} deg, ${M.widthPct(-1)} %`);
check("unknown correlation: one point", near(M.widthDeg(null), 0) && M.widthPct(null) === null, "ok");
check("breadth never under the sphere", near(M.acrossOf(0, 3, 0.2), 0.2) && near(M.acrossOf(30, 3, 0.2), 1.5, 1e-12), `${M.acrossOf(30, 3, 0.2).toFixed(3)}`);

console.log("place (X): azimuth on the floor, + to the right, - z ahead");
const c = M.posOf(0, 3, 1), r = M.posOf(30, 3, 1);
check("centre straight ahead", near(c.x, 0) && near(c.z, -3), `${c.x.toFixed(3)}, ${c.z.toFixed(3)}`);
check("30 deg right: the right speaker's direction", near(r.x, 1.5, 1e-12) && near(r.z, -3 * Math.cos(Math.PI / 6), 1e-12), `${r.x.toFixed(3)}, ${r.z.toFixed(3)}`);

console.log("easing");
let v = 0;
for (let i = 0; i < 6; i++) v = M.ease(v, 1, 0.1);
check("most of the way in 0.6 s, no overshoot", v > 0.99 && v < 1, v.toFixed(4));

console.log(bad === 0 ? "PASS stage-map" : `FAIL stage-map (${bad})`);
process.exit(bad === 0 ? 0 : 1);
