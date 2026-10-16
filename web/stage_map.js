// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 VerkCoding
//
// Where a part stands on the stage (roadmap step 8), as numbers only, so it can be tested
// without a browser (tests/stage_map_test.js). The axes (DESIGN.md "Goals"; owner, step 8):
//   X      the heard azimuth in degrees (+ is right), the speakers at ±30°;
//   Y      height from the spectral centroid on a log scale, 40 Hz to 12 kHz;
//   Z      distance from the listener by level relative to the whole mix (the master's level):
//          nearer and bigger when louder, over 30 dB (as the reference page the owner liked);
//   width  half the breadth along the arc, 30° × (1 − left/right correlation): one point at 0 %,
//          speaker to speaker at 100 %, past the speakers when out of phase (up to ±60°).
// Units: the floor's radius runs to 6.4, the speakers stand 3.0 out; y is up, -z is ahead.

export const Y_LO = 40, Y_HI = 12000, HEIGHT = 3.4, BASE = 0.15;
export const NEAR = 2.0, DEPTH = 3.6, SPAN_DB = 30;
export const SPEAKER_DEG = 30, FLOOR_DEG = 40;

const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

// Height of a centroid in Hz (clamped to 40 Hz .. 12 kHz).
export function yOf(hz) {
  const t = (Math.log2(hz) - Math.log2(Y_LO)) / (Math.log2(Y_HI) - Math.log2(Y_LO));
  return clamp(t, 0, 1) * HEIGHT + BASE;
}

// Level relative to the whole mix (dB) -> distance from the listener, and the sphere's radius.
export function distOf(rel) { return NEAR + clamp(-rel / SPAN_DB, 0, 1) * DEPTH; }
export function radOf(rel) { return 0.09 + Math.max(0, 1 + rel / SPAN_DB) * 0.30; }

// Correlation (-1 .. 1, or null) -> half the breadth along the arc, in degrees, and as a per cent.
export function widthDeg(corr) { return corr === null || corr === undefined ? 0 : SPEAKER_DEG * clamp(1 - corr, 0, 2); }
export function widthPct(corr) { return corr === null || corr === undefined ? null : Math.round(100 * (1 - corr)); }

// A floor position: azimuth (deg), distance, height -> { x, y, z }.
export function posOf(az, dist, y) {
  const a = az * Math.PI / 180;
  return { x: dist * Math.sin(a), y, z: -dist * Math.cos(a) };
}

// The level a part is drawn by: its heard Z against the master's own (the whole mix). Without a
// master level (the master is silent), against the loudest part instead.
export function relOf(z, mixZ, loudestZ) {
  const ref = mixZ !== null && mixZ !== undefined ? mixZ : loudestZ;
  return ref === null || ref === undefined ? 0 : z - ref;
}

// Kept off the stage: a part more than `threshold` dB under the loudest part shown (noise floors,
// dither, bleed). Step 5 found -86 dB of dither while stopped; the reference hid 34 dB down.
export function belowFloor(rel, loudestRel, threshold) { return rel < loudestRel - threshold; }

// Breadth along the arc at that distance, at least the sphere's own radius.
export function acrossOf(widthDegrees, dist, radius) { return Math.max(radius, dist * Math.sin(widthDegrees * Math.PI / 180)); }

// Easing towards a target over about tau seconds (frames come ten times a second; the screen
// draws at its own rate, so nothing jumps).
export function ease(cur, target, dt, tau = 0.12) { return cur + (target - cur) * (1 - Math.exp(-dt / tau)); }
