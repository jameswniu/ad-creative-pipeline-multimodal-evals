#!/usr/bin/env python3
"""eye_eval.py — reproduce MY EYE, not the model's intuition.

Built 2026-07-26 at my instruction: "go by my eyes. adjustment your measurements (evals) to mine
(what's good)." Every threshold here is fitted to clips I labelled, and the file is only allowed to
exist as long as it reproduces those labels. It is validated by `--validate`, which prints accuracy
against the whole labelled set; if that drops, the eval is wrong, not my eye.

## WHY THE EARLIER METERS ALL DIED

Nine models were built and killed on 2026-07-26, every one of them INVERTED on contact with my
labels: spasm ratio, face-vs-body relation, graph debt, rest fraction, gesture presence, voice
formant consensus, ASR confidence, lighting steadiness, and lap-hand clipping. The common mistake was
picking an axis the model found plausible and then fitting a number to it. What finally worked was DIFFING
the clips I passed against the ones I rejected and letting the difference name the axis.

## WHAT SURVIVES: ONE CONDITION, AND AN HONEST HOLE

Only ONE axis reproduces my labels, and it does not explain everything. Stated plainly rather than
dressed up, because overclaiming here is how the previous nine died.

  WORKS: BACKGROUND DETAIL. avatar_iii freezes everything except her, so a detailed background is edges
  holding unnaturally still for the whole clip. My goods measure 1.89-3.30; my busy-scene rejects
  measure 5.32 (sunrise beach), 11.09 and 11.78 (flower stall, florist). BG_MAX 4.5 is derived
  between my worst good (3.30) and my best reject (5.32).

  DOES NOT WORK: framing. The model claimed "head-on and centred" separated F3/F4 from the goods, and it
  looked obvious by eye. Measured, it is noise: left/right face asymmetry spans 0.24-0.88 on my
  GOODS and 0.24-0.88 on my REJECTS, because that number tracks side-lighting, not pose. And my
  good F1 is the MOST off-centre clip in the set (0.270). Adding these terms took agreement from
  82% down to 45%, so they are computed and printed but do NOT vote.

  UNEXPLAINED, AND NOW PROVEN UNMEASURABLE AT THIS RESOLUTION. The strongest result of the day is
  negative. The SAME LOOK produces clips I call good and clips I reject, and the pair is
  indistinguishable to every statistic computed here:

      F1 GOOD  motion 1.79  head 1.05  lower 2.77  jerk 0.151  burst 0.564  conc 0.098
      G5 bad   motion 1.83  head 1.07  lower 2.85  jerk 0.159  burst 0.572  conc 0.101

  Every term within 3%, i.e. noise. Same for the sconce look: M1 good, F3 and G4 rejected, same
  avatar, same settings. So the residual variance is PER-RENDER and lives in something frame
  differencing cannot see. This is a stronger finding than the nine falsified models: not "my metric
  was wrong" but "no metric at this resolution exists". Do not build a tenth. Burst looked promising
  on the sconce trio (0.549 good vs 0.653/0.670 bad) and failed to replicate on the sofa pair
  (0.564 vs 0.572), which is exactly how the previous nine started.

  CONSEQUENCE FOR THE LOGIC, not just the eval: a look that has ever produced a clip I called good
  is a GOOD LOOK. When a draw fails, RE-ROLL THE SAME LOOK rather than changing it. Changing the look
  after a bad draw is how six hours went into chasing look properties that were never the variable.

So this eval catches BUSY BACKGROUNDS reliably and nothing else. It is a filter, not a judge: it can
tell you a look will fail, never that a clip is good. My eye remains the only judge.

Usage:
  eye_eval.py <clip.mp4>        -> per-condition scores and a PASS/REJECT that mimics my eye
  eye_eval.py --validate        -> accuracy against every clip I have labelled
"""
import os
import subprocess
import sys

import numpy as np

BG_MAX = 4.5        # derived between my worst good (3.30) and my best reject (5.32)
ASYM_MAX = 0.22     # face left-right asymmetry; head-on is symmetric, 3/4 profile is not
OFFSET_MAX = 0.13   # |face centre - frame centre| as a fraction of width


def _gray(path: str, ss: str = "6", n: int = 1):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", ss, "-i", path,
                          "-frames:v", str(n), "-vf", "scale=256:256,format=gray",
                          "-f", "rawvideo", "pipe:1"], capture_output=True).stdout
    if len(raw) < 65536:
        return None
    return np.frombuffer(raw[:65536], dtype=np.uint8).reshape(256, 256).astype(np.float32)


def bg_detail(f) -> float:
    """Background busy-ness from the side bands only, so she is excluded."""
    side = np.concatenate([f[:, :64], f[:, 192:]], axis=1)
    return float((np.abs(np.diff(side, axis=1)).mean() + np.abs(np.diff(side, axis=0)).mean()) / 2)


def face_box(path: str):
    """Locate her face by temporal motion in the upper frame (never a fixed guess)."""
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", "5", "-t", "4", "-i", path,
                          "-vf", "fps=12,scale=256:256,format=gray", "-f", "rawvideo", "pipe:1"],
                         capture_output=True).stdout
    n = len(raw) // 65536
    if n < 8:
        return None
    fr = np.frombuffer(raw[:n * 65536], dtype=np.uint8).reshape(n, 256, 256).astype(np.float32)
    var = np.abs(np.diff(fr, axis=0)).mean(axis=0)
    var[int(0.70 * 256):, :] = 0        # ignore hands/lap; the mouth is the upper mover
    thr = np.percentile(var[var > 0], 97) if (var > 0).any() else 0
    ys, xs = np.where(var >= thr)
    if len(xs) < 5:
        return None
    return int(np.median(ys)), int(np.median(xs))


def framing(path: str, f):
    """Head-on-ness (left/right symmetry about the face axis) and centring."""
    fb = face_box(path)
    if fb is None:
        return None
    cy, cx = fb
    half = 34
    y0, y1 = max(0, cy - half), min(256, cy + half)
    lw = min(half, cx)
    rw = min(half, 256 - cx)
    w = min(lw, rw)
    if w < 12:
        return None
    left = f[y0:y1, cx - w:cx]
    right = f[y0:y1, cx:cx + w][:, ::-1]
    denom = max(float(np.abs(f[y0:y1, cx - w:cx + w]).mean()), 1e-6)
    asym = float(np.abs(left - right).mean() / denom)
    offset = abs(cx - 128) / 256.0
    return asym, offset


def evaluate(path: str):
    f = _gray(path)
    if f is None:
        return None
    bg = bg_detail(f)
    fr = framing(path, f)
    if fr is None:
        return {"bg": bg, "asym": None, "offset": None, "verdict": "UNJUDGEABLE"}
    asym, offset = fr
    # FRAMING TERMS ARE MEASURED BUT DO NOT VOTE (falsified 2026-07-26, minutes after the model proposed
    # them). The model claimed head-on-and-centred separated my labels. Measured, it does not: asymmetry
    # spans 0.24-0.88 on my GOODS and 0.24-0.88 on my REJECTS, because face-pixel symmetry tracks
    # SIDE-LIGHTING far more than pose, and my good F1 is the most off-centre clip in the set
    # (0.270). Including them dropped agreement from 82% to 45%. They are printed as context only.
    ok = bg <= BG_MAX
    return {"bg": bg, "asym": asym, "offset": offset, "verdict": "PASS" if ok else "REJECT"}


# Every clip I labelled on 2026-07-26. Paths are resolved at runtime; missing files are skipped.
LABELLED = [
    ("good/take1-final-pro.mp4", True), ("good/take3-final-pro.mp4", True),
    ("f5/raw1.mp4", True), ("f5/raw2.mp4", True), ("f5/raw5.mp4", True),
    ("f5/raw3.mp4", False), ("f5/raw4.mp4", False),
    ("r3/raw1.mp4", False), ("r3/raw2.mp4", False), ("r3/raw3.mp4", False),
    ("m2/raw1.mp4", True),
    ("g5/raw2.mp4", True), ("g5/raw3.mp4", True),
    ("g5/raw4.mp4", False), ("g5/raw5.mp4", False),
]


def validate(root: str):
    hits = tot = 0
    print(f"{'clip':22s} {'human':7s} {'eval':8s} {'bg':>6s} {'asym':>6s} {'offset':>7s}")
    for rel, good in LABELLED:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            continue
        r = evaluate(p)
        if not r or r["verdict"] == "UNJUDGEABLE":
            print(f"{rel:22s} {'good' if good else 'reject':7s} {'UNJUDGE':8s}")
            continue
        agree = (r["verdict"] == "PASS") == good
        hits += agree
        tot += 1
        print(f"{rel:22s} {'good' if good else 'reject':7s} {r['verdict']:8s} "
              f"{r['bg']:6.2f} {r['asym']:6.3f} {r['offset']:7.3f}  {'ok' if agree else 'MISS'}")
    if tot:
        print(f"\nagreement with my eye: {hits}/{tot} = {100 * hits / tot:.0f}%")
        if hits < tot:
            print("NOT 100%. My eye is the ground truth, so the miss means THIS FILE is wrong.")
    return hits, tot


def main():
    if "--validate" in sys.argv:
        root = sys.argv[sys.argv.index("--validate") + 1] if len(sys.argv) > 2 else "."
        h, t = validate(root)
        sys.exit(0 if t and h == t else 1)
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(64)
    r = evaluate(sys.argv[1])
    if not r:
        print("eye_eval: unreadable")
        sys.exit(64)
    if r["verdict"] == "UNJUDGEABLE":
        print(f"EYE UNJUDGEABLE: could not locate her face (bg {r['bg']:.2f})")
        sys.exit(3)
    print(f"EYE {r['verdict']}: bg {r['bg']:.2f} (max {BG_MAX}) | asym {r['asym']:.3f} "
          f"(max {ASYM_MAX}) | offset {r['offset']:.3f} (max {OFFSET_MAX})")
    sys.exit(0 if r["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
