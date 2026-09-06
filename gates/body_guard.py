#!/usr/bin/env python3
"""Refuse a still whose downstream crop wrecks HER: cuts part of her off, or shoves her to one side.

WHY (the author, 2026-08-03, on two rendered briefs he rejected): "the crop did cut her out on the
left for both... and she's pressing out close to the edge!"

WHY NOT crop_guard.py, which already exists: that one measures her FACE box against the crop
edges. On both stills he rejected, her face sat comfortably inside. What left the frame was her
hair and her shoulder. A face box cannot see that. This measures her SILHOUETTE, via
RobustVideoMatting (mobilenetv3, torch.hub), the same matte `matte_video.py` already uses for the
glass, so there is no new model and no new download.

TWO CHECKS, and only one of them is about edges.

  CUT          her alpha reaches the left or right column of the crop, so part of her was thrown
               away. Reported alongside `kept`, the fraction of her that survived. This is the
               visible-ratio measure the person-detection literature already uses (CrowdHuman
               defines visible ratio as visible box area over full box area); we are applying it
               at the frame boundary rather than to an occluder.

  OFF-CENTRE   her centre of mass sits further than `centre_tol` from the middle of the crop.
               Nothing is missing, she is simply parked in one half while the other half is
               background.

THE METRIC THAT WAS TRIED AND FALSIFIED, recorded so nobody re-derives it. The first version of
this file gated on CLEARANCE: the gap between her silhouette and the nearest side edge had to
exceed 12% of the crop width. That is wrong, and an offline replay over 44 shipped clips proved
it: the rule rejects 32 of 44 at 12% and 35 of 44 at 13%. She legitimately reaches the frame edge
in most good framings. A chest-up shot on the black void fills the width; a seated shot puts a
sleeve at one edge and a hand at the other. Clearance cannot tell "she fills the frame" from "she
is shoved into a corner", so it fails almost everything.

WHAT ACTUALLY SEPARATES HIS CALLS is placement, not clearance. Same 44-clip replay, centre offset:

    aj-brief-20260803  (look 91bb18e1)  offset 0.219   REJECTED by the author
    aj-brief-20260731  (look 7a25e249)  offset 0.187   REJECTED by the author
    aj-brief-...-recut (look 98f0e8c8)  offset 0.044   KEPT by the author

    a bar at 0.12 rejects EXACTLY those two out of all 44 shipped clips, and nothing else.

The same holds measured on the stills rather than the renders: his keepers 0.021 and 0.035, his
rejects 0.186 and 0.218. The gap between 0.044 and 0.187 is wide and empty, so 0.12 is not perched
on a knife edge. Asymmetry (the difference between the left and right gaps) also separates the
three known cases but rejects 9 of 44, seven of which shipped fine, so it is second best.

Bottom and top are NOT checked here: the bottom is the safe edge by the author's standing rule, and the
top (head) is already covered by crop_guard's HEAD check with its hair margin.

Usage:  body_guard.py <image-or-video> [--aspect 1.0] [--centre-tol 0.12] [--frames 1]
Exit:   0 clean, 2 CROPS HER, 1 could not judge
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

os.environ.setdefault("TORCH_HOME", str(Path(__file__).resolve().parents[1] / "models" / "torch"))
import torch  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quilt import ASPECT  # noqa: E402

_M = None


def model():
    global _M
    if _M is None:
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        _M = (torch.hub.load("PeterL1n/RobustVideoMatting", "mobilenetv3",
                             trust_repo=True).to(dev).eval(), dev)
    return _M


def grab(path: Path, t: float) -> np.ndarray:
    if path.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp"):
        return np.asarray(Image.open(path).convert("RGB"))
    out = Path(tempfile.mktemp(suffix=".png"))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", str(t), "-i", str(path),
                    "-frames:v", "1", str(out)], check=True)
    try:
        return np.asarray(Image.open(out).convert("RGB"))
    finally:
        out.unlink(missing_ok=True)


def crop_rect(h: int, w: int, aspect: float) -> tuple[int, int, int, int]:
    """The rectangle quilt.crop_to_aspect keeps. Same arithmetic as crop_guard, on purpose."""
    target_w = int(round(h * aspect))
    if target_w <= w:
        x0 = (w - target_w) // 2
        # GLASS_CROP_X0 (2026-08-07): honor the same anchor override quilt.py honors, so the
        # gate judges the window that will actually ship. Set by brief_to_glass.sh from
        # crop_anchor.py (silhouette-centred), or by hand for an experiment. Clamped identically.
        import os as _os
        _e = _os.environ.get("GLASS_CROP_X0")
        if _e not in (None, ""):
            try:
                x0 = max(0, min(int(_e), w - target_w))
            except ValueError:
                pass
        return x0, 0, x0 + target_w, h
    target_h = int(round(w / aspect))
    return 0, 0, w, target_h            # top-anchored, same as quilt.py


def alpha_of(img: np.ndarray) -> np.ndarray:
    m, dev = model()
    h, w = img.shape[:2]
    src = torch.from_numpy(img.copy()).permute(2, 0, 1).float().div(255).unsqueeze(0).to(dev)
    # RVM guideline: internal downsample so the net sees ~512px, same as matte_video.py.
    ratio = min(512.0 / max(w, h), 1.0)
    with torch.no_grad():
        _fgr, pha, *_ = m(src, downsample_ratio=ratio)
    return pha[0, 0].clamp(0, 1).cpu().numpy()


# SUNK: a dark, COLOURLESS region inside her own silhouette on a void plate. the author, 2026-08-16,
# on a still where she held a black portfolio against the black background: "you don't put the black
# object, man ... Even if the black object is not at the edges, it's as if there's a hole."
#
# The rule is deliberately the SAME one crop_guard already applies to her garment (TORSO_LUM_MIN 40
# AND TORSO_CHROMA_MIN 10): dark alone is not the defect, dark AND colourless is. What this adds is
# WHERE it looks. crop_guard samples a fixed torso box, which is blind to anything that box misses;
# this measures her whole silhouette, so it also catches a black tee worn under an open coloured
# cardigan, which the torso box reads as the cardigan and passes.
#
# MEASURED BEFORE IT SHIPPED, over 51 void plates from taste/pairs plus the 2026-08-16 candidates.
# Two earlier metrics were tried and DISCARDED because they did not separate, and they are recorded
# here so nobody rebuilds them: (a) plain dark fraction inside the silhouette put the black-folder
# still at 0.303, BELOW five clean stills topping out at 0.438, because a dark teal top scores the
# same as a black prop; (b) dark-and-matte-ambiguous put it 4th, still inside the clean spread.
# Only dark-AND-colourless separated:
#
#   0.1899  black portfolio, frontal (cand-C)                 BAD
#   0.1299  black tee under an open rust cardigan             BAD  (torso box missed this one)
#   0.0980  black portfolio, angled (cand-D)                  BAD  and it REACHED THE GLASS
#   ------- empty band, no still measured in it -------
#   0.0752  grey blazer over sage top                         clean
#   0.0652  clean
#   0.0007  median of all 48 remaining void plates
#
# The floor sits in the empty band. At 0.085 it rejects 3 of 3 verified-bad stills and 0 of 48
# clean ones. HONEST LIMIT: only three positives, and two are the same folder from one generation,
# so this is calibrated on few defects. Widen the corpus before tightening it further, and do NOT
# lower it toward 0.075 on argument alone; that band is empty by measurement, not by reasoning.
SUNK_LUM_MAX = 40.0      # same brightness floor crop_guard uses for a neutral garment
SUNK_CHROMA_MAX = 10.0   # same colour floor; clearing EITHER means it reads against the void
SUNK_MAX = 0.085         # fraction of her silhouette allowed to be both dark and colourless
SUNK_ERODE = 6           # pull in from the matte edge so the soft silhouette edge is not counted
VOID_BG_MIN = 0.80       # only a genuine black plate can hide an object; a scene explains its darks


def _sunk_frac(img: np.ndarray, a: np.ndarray) -> tuple[float, float]:
    """Fraction of her silhouette that is dark AND colourless, plus how black the plate is."""
    from PIL import ImageFilter
    lum = img.astype(float).mean(axis=2)
    chroma = img.astype(float).max(axis=2) - img.astype(float).min(axis=2)
    outside = a < 0.10
    bg_black = float((lum[outside] <= 25).mean()) if outside.sum() > 1000 else 0.0
    inside = a > 0.90
    if SUNK_ERODE:
        m = Image.fromarray((inside * 255).astype(np.uint8)).filter(
            ImageFilter.MinFilter(SUNK_ERODE * 2 + 1))
        inside = np.asarray(m) > 127
    n = int(inside.sum())
    if n < 5000:
        return 0.0, bg_black
    sunk = inside & (lum < SUNK_LUM_MAX) & (chroma < SUNK_CHROMA_MAX)
    return float(sunk.sum() / n), bg_black


def judge(path: Path, aspect: float, centre_tol: float, frames: int, thr: float = 0.5) -> dict:
    times = [1.0, 4.0, 8.0][:max(1, frames)]
    findings, checked, samples = [], 0, []
    for t in times:
        try:
            img = grab(path, t)
        except Exception:
            continue
        h, w = img.shape[:2]
        a = alpha_of(img)
        x0, y0, x1, y1 = crop_rect(h, w, aspect)
        sub = a[y0:y1, x0:x1]
        cw = x1 - x0
        cols = (sub > thr).sum(axis=0)
        if cols.max() == 0:
            continue                      # she was not found; UNKNOWN, never a pass
        checked += 1
        nz = np.nonzero(cols)[0]
        lm = float(nz[0]) / cw
        rm = float(cw - 1 - nz[-1]) / cw
        kept = float((sub > thr).sum()) / max(1.0, float((a > thr).sum()))
        # Centre of MASS, not the midpoint of her bounding box. An outstretched arm should not
        # count as much as her torso, and mass weights it that way for free.
        cx = float((np.arange(cw) * cols).sum() / cols.sum()) / cw
        off = cx - 0.5
        samples.append({"t": t, "left": round(lm, 4), "right": round(rm, 4),
                        "kept": round(kept, 4), "centre": round(cx, 4),
                        "offset": round(off, 4)})

        # `kept` and the left/right margins are REPORTED but do NOT gate. A CUT check on them was
        # built and then removed on 2026-08-04, measured rather than argued: over 44 shipped clips
        # it never once rejected anything that centre offset had not already rejected, and at the
        # panel's 3:4 it fires on 34 of the 44, because she legitimately extends past a tall crop
        # in most framings (24 of those 34 touch BOTH sides, which just means she spans the frame).
        # Worst survival across all 44 was 0.76 and the median 0.93, so there is no clean band to
        # gate on either. the author: "just keep the one that works." The numbers stay in the output
        # because they are free and diagnostic; they are simply not a verdict.
        sf, bgb = _sunk_frac(img[y0:y1, x0:x1], a[y0:y1, x0:x1])
        samples[-1]["sunk_frac"] = round(sf, 4)
        samples[-1]["bg_black"] = round(bgb, 3)
        if bgb >= VOID_BG_MIN and sf > SUNK_MAX:
            findings.append(
                f"t={t}s SUNK: {sf:.3f} of her silhouette is both darker than "
                f"{SUNK_LUM_MAX:.0f} and less colourful than {SUNK_CHROMA_MAX:.0f}, over the "
                f"{SUNK_MAX:.3f} ceiling. On a black plate that region does not read as part of "
                f"her, it reads as a hole punched through her. Usually a black prop she is "
                f"holding, or a black garment under an open coloured one; re-roll with anything "
                f"she holds or wears in a light or mid tone, or carrying real colour")

        if abs(off) > centre_tol:
            side = "LEFT" if off < 0 else "RIGHT"
            far = "right" if off < 0 else "left"
            findings.append(
                f"t={t}s OFF-CENTRE {side}: her centre of mass sits at {cx:.3f} across the crop "
                f"(tolerance {0.5 - centre_tol:.2f} to {0.5 + centre_tol:.2f}); the {far} of the "
                f"frame is background")
    # WHICH check fired, carried in the payload, matching crop_guard.py. There is only one check
    # here today (OFF-CENTRE), so this looks redundant, and that is exactly the point: crop_guard
    # also had one meaningful check when it hardcoded CROPS_HER, and by 2026-08-05 it had five and
    # was telling the author a clip was cropped when it was under-lit. A caller cannot report the real
    # reason if the payload never carries it. Adding a second check here must not silently
    # reintroduce that, so the reason ships from the start.
    reasons = sorted({f.split(":", 1)[0].split("s ", 1)[-1].strip() for f in findings})
    return {"checked_frames": checked, "findings": findings, "samples": samples,
            "reasons": reasons,
            "verdict": "UNKNOWN" if checked == 0 else ("REJECT" if findings else "CLEAN")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--aspect", type=float, default=ASPECT)
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--centre-tol", type=float, default=0.12,
                    help="how far her centre of mass may sit from the middle of the crop, as a "
                         "fraction of crop width. 0.12 rejects exactly the two clips the author "
                         "rejected out of 44 shipped, and nothing else")
    ap.add_argument("--look-id", default=None,
                    help="HeyGen look id this still belongs to. On a CLEAN verdict ONLY, records "
                         "a pass under state/crop-gate/, which enforce-crop-gate-on-render.sh "
                         "requires before it will let the paid render through. The record is "
                         "written HERE, by the measurement itself, so it cannot be produced "
                         "without actually running the gate and actually passing it")
    a = ap.parse_args()
    r = judge(Path(a.target), a.aspect, a.centre_tol, a.frames)
    if a.look_id and r["verdict"] == "CLEAN":
        d = Path(__file__).resolve().parents[1] / "state" / "crop-gate"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{a.look_id}.json").write_text(json.dumps(
            {"look_id": a.look_id, "target": str(Path(a.target).resolve()),
             "aspect": a.aspect, "centre_tol": a.centre_tol, **r}))
    # JSON to stdout ONLY, on one line: torch.hub prints a cache banner on import, so a caller
    # doing `body_guard.py x | jq` must be able to read the LAST line and get clean JSON.
    print(json.dumps(r))
    # CROPS_HER stays as an exit-code key so an older caller pinned to it cannot silently start
    # returning 1 (an infra error) for what is really a rejection.
    return {"CLEAN": 0, "REJECT": 2, "CROPS_HER": 2}.get(r["verdict"], 1)


if __name__ == "__main__":
    raise SystemExit(main())
