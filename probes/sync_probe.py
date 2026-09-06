#!/usr/bin/env python3
"""sync_probe.py — does her mouth TRAIL the audio? (the lipsync axis, measured)

Built 2026-07-26 after I flagged two clips with "the lip sync is a bit off". This is the FIRST
metric all day that separates my labels, and it works because it measures the thing I named
instead of a pixel statistic the model found plausible. Nine earlier models died measuring the wrong axis.

## THE SIGNAL

Cross-correlate MOUTH-BAND motion against the AUDIO ENVELOPE and find the lag that maximises it.
Negative lag = mouth moves with or slightly ahead of the sound. Positive lag = mouth TRAILS.

    take3-final-pro   -160ms   verdict: good
    M1               -80ms   verdict: good
    F1               -40ms   verdict: good
    G1               +40ms   verdict: fine
    G4b             +120ms   verdict: "the lip sync is a bit off"
    G5b             +240ms   verdict: "the lip sync is a bit off"

My acceptable band is -160 to +40ms; my rejects are +120 and +240. LAG_MAX sits at +2 frames
(+80ms), between them. 240ms is far beyond the ~100ms where audio/video desync becomes perceptible
to a human, so the number and the eye agree here for a mechanically sensible reason.

This is also exactly avatar_iii's documented weakness ("softer lip-sync, mouth lags slightly"). So
the defect is the ENGINE's known failure mode showing up per-draw, not a look or a script problem.

## IT IS NOISY. DO NOT GATE ON IT. (added within the hour, by the stability check the model skipped)

Measuring the SAME clip in thirds shows the lag swinging 6-10 frames:

    F1 (verdict: good)  whole -1f   thirds -1 / -5 / +1
    M1 (verdict: good)  whole -2f   thirds -6 / +4 / +0
    G5b (verdict: off)  whole +6f   thirds -4 / +6 / +3
    G4c (verdict: off)  whole +5f   thirds +5 / +5 / +5

Only the last is stable. So the whole-clip figure is largely an average of noise, and the 8/8
agreement it first showed was substantially luck. It was wired into ship_gate as a BLOCKER and
downgraded to a DISCLOSURE the same hour. Report the number, never let it refuse a clip.

The one thing that might survive: G4c is CONSISTENTLY +5 across every third while the goods
OSCILLATE around zero. Consistency-of-sign could be the real signal rather than the mean. That is a
hypothesis with n=1, explicitly not implemented, and it is exactly the shape of the ten models that
have already died today. Do not build it without a much larger labelled set.

## WHAT IT IS NOT

It does not judge whether a clip is good. It judges ONE axis, the one I named. A clip can sit at
0ms and still be rejected for something else entirely; the F1-vs-G5 pair proved there is residual
per-render variance no frame metric can see. Use this to catch trailing mouths, nothing more.

Correlation strength is reported but deliberately NOT gated: it ranges 0.15-0.32 on my GOODS and
0.05-0.23 on my rejects, which overlaps. Only the LAG separates.

Usage: sync_probe.py <clip.mp4> [--json]
Exit 0 in-band / 1 mouth trails / 64 unreadable.
"""
import json
import subprocess
import sys

import numpy as np

FPS = 25
# The band is two sided. Gating only the upper edge let a mouth running far
# AHEAD of the sound through, which the docstring's own band excludes: a lead
# is as wrong as a trail, it just looks different. -4 frames is the -160ms the
# labelled passes bottom out at.
LAG_MIN = -4
LAG_MAX = 2          # frames (+80ms); my goods run -4..+1, my rejects +3 and +6
SEARCH = 6           # +/- frames to search


def mouth_series(path: str):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-vf",
                          f"fps={FPS},scale=192:192,format=gray", "-f", "rawvideo", "pipe:1"],
                         capture_output=True).stdout
    n = len(raw) // 36864
    if n < 40:
        return None
    fr = np.frombuffer(raw[:n * 36864], dtype=np.uint8).reshape(n, 192, 192).astype(np.float32)
    var = np.abs(np.diff(fr, axis=0)).mean(axis=0)
    var[int(0.70 * 192):, :] = 0          # hands/lap are not the mouth
    if not (var > 0).any():
        return None
    ys, xs = np.where(var >= np.percentile(var[var > 0], 98))
    cy, cx = int(np.median(ys)), int(np.median(xs))
    band = fr[:, max(0, cy - 10): cy + 14, max(0, cx - 16): cx + 16]
    return np.abs(np.diff(band, axis=0)).mean(axis=(1, 2))


def envelope(path: str, n: int):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-ac", "1",
                          "-ar", "16000", "-f", "s16le", "pipe:1"], capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    hop = 16000 // FPS
    return np.array([np.sqrt((x[i * hop:(i + 1) * hop] ** 2).mean())
                     for i in range(min(n, len(x) // hop))])


def measure(path: str):
    m = mouth_series(path)
    if m is None:
        return None
    e = envelope(path, len(m))
    k = min(len(m), len(e))
    if k < 40:
        return None
    m, e = m[:k], e[:k]
    m = (m - m.mean()) / max(m.std(), 1e-9)
    e = (e - e.mean()) / max(e.std(), 1e-9)
    best_c, best_l = -9.0, 0
    for lag in range(-SEARCH, SEARCH + 1):
        a, b = m[SEARCH + lag: k - SEARCH + lag], e[SEARCH: k - SEARCH]
        if len(a) != len(b) or len(a) < 20:
            continue
        c = float(np.corrcoef(a, b)[0, 1])
        if c > best_c:
            best_c, best_l = c, lag
    return best_c, best_l


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(64)
    r = measure(sys.argv[1])
    if r is None:
        print("sync_probe: unreadable or too short")
        sys.exit(64)
    corr, lag = r
    ms = lag * 1000 // FPS
    ok = LAG_MIN <= lag <= LAG_MAX
    out = {"clip": sys.argv[1], "lag_frames": lag, "lag_ms": ms,
            "corr": round(corr, 3), "verdict": "IN BAND" if ok else "MOUTH TRAILS"}
    if "--json" in sys.argv:
        print(json.dumps(out))
    else:
        print(f"SYNC {out['verdict']}: lag {ms:+d}ms (max +{LAG_MAX * 1000 // FPS}ms) "
              f"| corr {corr:.3f} (not gated, it overlaps on my labels)")
        if not ok:
            print(f"  her mouth trails the audio by {ms}ms. My labelled rejects were +120 and "
                  f"+240ms; my passes ran -160 to +40ms. Re-roll rather than ship.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
