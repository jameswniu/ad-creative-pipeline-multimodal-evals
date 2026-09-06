#!/usr/bin/env python3
"""level_probe.py — does the clip hold ONE lighting level all the way through?

my spec (2026-07-26): "just bc u bright dim bright dim predictably don't mean we
pass. Passing means you gotta be like dim all the way, or bright all the way." A regular
pulse is still a failure. Constancy is the criterion, at any chosen level.

Three things must hold steady over time, because a clip can fake any one of them:
  face      her face's own level          (the engine re-lights her frame to frame)
  scene     the background's level         (exposure wander)
  relation  face minus body                (a masked grade can flatten the face average
                                            while her face still swings against her body,
                                            which is what the eye actually reads as pulsing)

Benchmarks measured on avatar_iv (the standard I set): face 4.2, scene 2.1,
relation 10.3. avatar_iii raw on a hard-rim night look: 22, 13, 24.

Level classes: dim (<70), mid (70-120), bright (>120) — both dim-all-the-way and
bright-all-the-way are valid targets; only the WANDER is the defect.

Usage: level_probe.py <video.mp4> [--json]
Exit 0 constant / 1 wandering.
"""
import json
import subprocess
import sys

import numpy as np

# Calibrated TO avatar_iv, the standard I set (it measures 7.9 / 2.1 / 12.1 on the
# clip I linked), with a hair of headroom. Passing means "at least as steady as iv".
FACE_MAX = 8.0
# SCENE_MAX re-derived 2026-07-26 (second time; the first re-derivation was rolled back in a
# blanket rebase): 3.0 was authored (iv's 2.1 plus headroom) and failed clips I approved.
# My passes measure 3.7-3.8 (the 3.8 window is IN the golden set); my rejects 7.7+.
SCENE_MAX = 5.0
RELATION_MAX = 12.5


def series(path: str):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-vf",
                          "scale=96:96,format=gray", "-f", "rawvideo", "pipe:1"],
                         capture_output=True).stdout
    n = len(raw) // 9216
    if n < 30:
        return None
    fr = np.frombuffer(raw[: n * 9216], dtype=np.uint8).reshape(n, 96, 96).astype(np.float32)
    # locate her by temporal-motion centroid in the upper frame, never a fixed guess
    var = np.abs(np.diff(fr, axis=0)).mean(axis=0)
    var[int(0.62 * 96):, :] = 0
    ys, xs = np.where(var >= np.percentile(var[var > 0], 96))
    cy, cx = int(ys.mean()), int(xs.mean())
    face = fr[:, max(0, cy - 7): cy + 7, max(0, cx - 7): cx + 7].reshape(n, -1).mean(axis=1)
    body = fr[:, min(95, cy + 18): min(96, cy + 32), max(0, cx - 7): cx + 7].reshape(n, -1).mean(axis=1)
    scene = np.concatenate([fr[:, :, :24].reshape(n, -1), fr[:, :, 72:].reshape(n, -1)], axis=1).mean(axis=1)
    return face, body, scene


def spread(x) -> float:
    return float(np.percentile(x, 95) - np.percentile(x, 5))


def main():
    positional = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(positional) < 1:
        print("usage: level_probe.py CLIP.mp4 [--json]", file=sys.stderr)
        return 2
    path = positional[0]
    s = series(path)
    if s is None:
        print("level_probe: clip too short to judge")
        sys.exit(64)
    face, body, scene = s
    f, sc, rel = spread(face), spread(scene), spread(face - body)
    level = float(np.median(face))
    cls = "dim" if level < 70 else ("mid" if level <= 120 else "bright")
    ok = f <= FACE_MAX and sc <= SCENE_MAX and rel <= RELATION_MAX
    out = {"clip": path, "level": round(level, 1), "level_class": cls,
           "face_wander": round(f, 1), "scene_wander": round(sc, 1),
           "relation_wander": round(rel, 1),
           "verdict": "CONSTANT" if ok else "WANDERING"}
    if "--json" in sys.argv:
        print(json.dumps(out))
    else:
        print(f"LEVEL {out['verdict']}: {cls} at {out['level']} | face {f:.1f} (<={FACE_MAX}) "
              f"| scene {sc:.1f} (<={SCENE_MAX}) | face-vs-body {rel:.1f} (<={RELATION_MAX})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    sys.exit(main())
