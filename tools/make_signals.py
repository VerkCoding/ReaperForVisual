# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 VerkCoding
"""Write the synthetic test signals the fixtures use, with exactly known levels.

    python tools/make_signals.py [folder]     # default: %TEMP%/rfv-signals

sine1k_m12.wav    mono, 1 kHz sine, peak 0.25 (-12.04 dBFS), 48 kHz, 30 s
st_500L_3kR.wav   stereo, 500 Hz left and 3 kHz right at peak 0.25, uncorrelated, 48 kHz, 30 s
noise_m20.wav     mono, white noise, RMS 0.1 (-20 dBFS), fixed seed, 48 kHz, 30 s
noise_antiphase.wav  stereo, the same noise left and polarity-inverted right (correlation -1)
sine_L_only.wav / sine_R_only.wav  stereo, the 1 kHz sine in one channel, silence in the other
Standard library only, so it runs anywhere Python does.
"""

from __future__ import annotations

import math
import os
import random
import struct
import sys
import tempfile
import wave
from pathlib import Path

SR, SECONDS, A = 48000, 30, 0.25


def write(path: Path, channels: list[list[float]]) -> None:
    n = len(channels[0])
    with wave.open(str(path), "wb") as w:
        w.setnchannels(len(channels))
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            for ch in channels:
                frames += struct.pack("<h", max(-32768, min(32767, round(ch[i] * 32767))))
        w.writeframes(bytes(frames))


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(os.environ.get("TEMP", tempfile.gettempdir())) / "rfv-signals"
    out.mkdir(parents=True, exist_ok=True)
    n = SR * SECONDS
    sine = [A * math.sin(2 * math.pi * 1000 * i / SR) for i in range(n)]
    write(out / "sine1k_m12.wav", [sine])
    left = [A * math.sin(2 * math.pi * 500 * i / SR) for i in range(n)]
    right = [A * math.sin(2 * math.pi * 3000 * i / SR) for i in range(n)]
    write(out / "st_500L_3kR.wav", [left, right])
    rnd = random.Random(1234)
    noise = [rnd.gauss(0.0, 0.1) for _ in range(n)]
    write(out / "noise_m20.wav", [noise])
    write(out / "noise_antiphase.wav", [noise, [-v for v in noise]])
    silence = [0.0] * n
    write(out / "sine_L_only.wav", [sine, silence])
    write(out / "sine_R_only.wav", [silence, sine])
    for f in sorted(out.glob("*.wav")):
        print(f"{f}  {f.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
