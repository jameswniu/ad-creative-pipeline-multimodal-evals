#!/usr/bin/env python3
"""Refuse a clip whose panel crop cuts HER.

WHY (the author, 2026-08-03, watching the charcoal void portrait on the glass): "her head is cut off.
Can we do a hard gate for both production and experimental? If you cut off the head or the body,
the sides, right? If you cut off the bottom, it is okay."

The panel is 3:4. Anything not already 3:4 loses pixels on the way in, and WHICH edge pays is the
whole question. A 9:16 source is taller than 3:4, so height has to go; until today crop_to_aspect
took it evenly off both ends and the top half of that trade was her head. That anchor is now fixed
(top-anchored), and this is the gate that catches whatever the anchor cannot: a source framed so
tightly that even a top-anchored crop clips her, or a landscape source where she sits far enough
off-centre that the side crop cuts into her.

THE RULE, exactly as he stated it:
    top   (head)      -> never
    left/right (body) -> never
    bottom            -> fine, that is where the loss belongs

WHAT IT MEASURES. Her face is found in the FULL frame with the same detector the identity gate
uses (InsightFace buffalo_l). The crop rectangle is then computed the way quilt.py computes it, and
the face box is checked against the three forbidden edges. A face stands in for the head, so the
top check carries a margin: hair and crown sit above the detected box, and a crop that grazes the
forehead has already taken the top of her head.

A DETECTOR FAILURE IS NOT A PASS. If no face is found at all, that is reported as UNKNOWN rather
than as clean, and the caller decides; a clip can legitimately have her turned away in the sampled
frame, which is why several frames are sampled.

THE ZOOM CHECK (added 2026-08-04) rides here rather than in body_guard because it needs the FACE
box, which this file already has, and body_guard runs in a different venv with no face detector.

WHY (the author, 2026-08-04): "the videos all have her zoomed out" since the still lane swapped to the
personal model. Derived from HIS OWN taste rather than argued: the Photos album `the golden-set album`,
93 videos he chose to keep, measured at face height over frame height, which is the standard
cinematography measure of shot size.
His 5th percentile is 0.169; the floor is 0.16, which the author chose off the measured strip and which
is the better number: it sits in an EMPTY band (nothing between 0.153 and 0.162), so it is not
perched on a cluster the way the percentile was.

WHAT WAS TRIED AND DROPPED, so nobody re-derives it. Three metrics were measured against the same
93 goldens plus 39 production clips:

  silhouette height   REJECTED. His golden set spans it, because he genuinely likes wide framings:
                      the pier dress, the blue-dress walk, and the blazer desk talking heads all
                      sit below 0.90 and he kept every one. A floor there throws away 24 of 93.
  silhouette coverage REJECTED as an added arm. ORed with the face floor it rejects 8 goldens
                      instead of 5 and catches only one extra clip, a lane-test outlier that was
                      never a brief. Strictly worse, so it is measured and reported, not gated.
  face height         KEPT. At 0.16 it rejects 2 of 92 goldens (the pier dress at 0.101 and the
                      blue-dress walk at 0.115, both full-body walking shots) and BOTH post-swap
                      briefs whose framing the author caught by eye, at 0.126 and 0.153. One pre-swap
                      holoblack at 0.138 also clips it.

WHAT THE FLOOR CANNOT DO, stated plainly because it matters more than the floor: his taste is
BROAD, so a gate calibrated on it only ever catches the disasters. Post-swap production sits at
0.226 median against his 0.262, still inside his band; the house style used to be 0.348, tighter
than his own set. Closing that gap is the D and F framing clause, not this gate.

MEASURABLE BEFORE THE SPEND. Framing carries from the still to the render essentially exactly:
over the three looks where both exist, face height moved by at most 0.004. So gating the still
gates the render.

Usage:  crop_guard.py <video-or-image> [--aspect 0.75] [--frames 3] [--top-margin 0.06]
Exit:   0 clean, 2 CROPS HER or ZOOMED OUT, 1 could not judge
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import colorsys

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quilt import ASPECT  # noqa: E402

# --- the three checks added 2026-08-04, after the author looked at ten generated stills and named five
# that every existing gate had passed: "why are there blue lights and then dramatic lighting and
# shit?" and "this one is facing away from the camera... Those are not supposed to pass."
#
# All three thresholds are read off the 93 videos in his Photos album `the golden-set album`, the same
# source as the zoom floor. Together they reject EXACTLY the five he named and 0 of 85 goldens.
#
# TWO OF THEM ARE VOID-ONLY, and that is the whole reason they were invisible before. the author stated
# the rule directly on 2026-08-04: "we are okay if the scene is dark in hologram, but we're not okay
# if it's just holoblack. It's the same as the neon light one in the club. If she's in a Club, then
# she can be neon-skinned, but otherwise she can't if she's in a holoblack." His golden set CONTAINS
# cold-rim clips he loves: the club-night neon reference he crowned ("this wins") is hue 178, and a
# city-night clip is hue 199. Both are SCENES, where the world explains the colour and she is warmly
# lit inside it. What he rejected was a VOID plate with an electric blue edge traced on her outline.
# Same for exposure: his darkest keeper is a warm lamplit scene at face luminance 44 where she reads
# perfectly, DARKER than the murky void he rejected at 47, so raw luminance cannot separate them and
# a flat floor would throw away the lamp scene. On a void she is the only thing in frame, so being
# under-lit is a defect; in a dim room it is a look.
#
# EVERYTHING THEREFORE RESTS ON THE VOID CLASSIFIER, and getting it wrong is silent in both
# directions: too loose and these checks fire on his night scenes, too tight and a holoblack walks
# past them. See VOID_PURE below for what it measures and why darkness alone was the wrong organ.
YAW_MAX = 35.0        # golden max 33.3, p99 32.2; the still he rejected was -41.6
# A void is DARK **AND** EMPTY, and the second half is the one that does the work. Three earlier
# versions of this test measured only darkness and all three misread night scenes as void plates:
# his moonlit-beach golden is blacker than most real voids, so the void-only checks started firing
# on scenes they were written to leave alone, and the exposure floor got calibrated on a polluted
# set. Tightening the darkness threshold does not fix this, it only moves the boundary: measured at
# true black instead of merely dim, 4 labelled scenes and 12 labelled voids looked separable, and
# then a club-corridor still landed at 0.377, inside the supposed gap. It was a brick wall, a neon
# sign and a crowd. Darkness is simply the wrong organ, at every threshold.
#
# What actually separates them is whether there is ANYTHING IN FRAME BESIDES HER. On a void she is
# the only lit thing; a dim room, a night street and a club all have light away from her. Measured
# over 12 scenes (4 labelled plus the 8 club stills of 2026-08-05) and 12 labelled voids, as the
# fraction of the region far from her that reads above luminance 60:
#     voids   0.000 to 0.011
#     scenes  0.025 to 0.711        empty band, and the club corridor sits at 0.035
# Both conditions are required, so a still is judged by void rules only when it is dark AND has
# nothing else lit in it. That is the conservative direction: a scene wrongly called a void gets
# rejected for lighting he likes and legitimately paid for.
VOID_PURE = 0.30      # DARK: fraction of the crop under luminance 8
VOID_FARLIT = 0.02    # EMPTY: fraction of the region far from her above luminance 60
# On the golden set the pair calls 7 clips voids, and all 7 are his holoblack productions by name.
RIM_SAT = 0.45        # below this there is no rim worth calling coloured
RIM_WARM = (10.0, 65.0)   # hue degrees; every warm rim in the golden set is 27-50
# THE WARDROBE CHECK, void-only, added 2026-08-05. Written in three layers on the author's design, so
# that the layer most likely to go stale is the smallest one and the reasoning above it survives a
# recalibration.
#
# CONCEPTUAL. The hologram needs a BODY, not just a face. A void plate gives the lenticular exactly
# one subject and no scenery, so whatever the garment fails to show is simply missing depth. The
# void is NEUTRAL black, which is the whole reason this is not a brightness question: a garment
# merges into it by sharing BOTH its darkness and its neutrality, and escapes by breaking either
# one. the author named the defect watching a black turtleneck reach the glass, and the tell is that it
# looks fine on a screen: a monitor shows you her face and rim and lets you infer a body that the
# panel will not draw.
#
# STRUCTURAL. Two independent escapes, either one sufficient, because they are the two ways to stop
# sharing something with the void:
#     bright enough   a neutral garment separates on luminance alone
#     coloured enough a dark garment separates on chroma alone
# Neither arm alone fits his labels, and that asymmetry is the finding: a garment DARKER than one he
# rejected can pass, if it carries colour. Any future re-derivation should expect to keep this shape
# and move only the numbers below; if a single dimension ever appears to suffice, the corpus is too
# narrow rather than the rule too complex.
#
# PHYSICAL, and deliberately thin. Two thresholds and the pair that forces the shape. The full
# labelled corpus lives in tests/fixtures/gate-calibration.json, which is where measurements belong;
# duplicating it here would rot. Both numbers sit mid-band, not on a cluster.
#     navy      luminance 18.7, chroma 22  PASS
#     charcoal  luminance 26.0, chroma  3  FAIL   <- brighter, and still fails
TORSO_LUM_MIN = 40.0   # a NEUTRAL garment must be at least this bright to read against the void
TORSO_CHROMA_MIN = 10.0  # or else carry at least this much colour, which buys the same separation
LIT_MIN = 0.68        # 0.58 until the void test above stopped counting night scenes as voids.
# With the scenes out of the calibration set the dimmest TRUE void he has kept lights 0.710 of her
# face box, not 0.605, and the shaded plate he rejected on 2026-08-04 sits at 0.655. 0.68 is the
# midpoint of that gap. His older rejects were 0.55 and 0.40, well clear.

_APP = None


def app():
    global _APP
    if _APP is None:
        from insightface.app import FaceAnalysis
        a = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])  # pii-allow, a model name, not a time
        a.prepare(ctx_id=-1, det_size=(640, 640))
        _APP = a
    return _APP


def grab(path: Path, t: float) -> np.ndarray:
    """One frame as RGB. Images pass through; videos get sampled at t seconds."""
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
    """The rectangle quilt.crop_to_aspect keeps: (x0, y0, x1, y1). Same arithmetic, on purpose."""
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


def is_void(pl: dict, declared: bool = False) -> bool:
    """Is this a black plate rather than a dark scene? Takes a dict from plate().

    THE ONLY PLACE THIS QUESTION IS ANSWERED. still_alien.sh imports it too, because a second
    definition living somewhere else is how the alien gate ended up running on scenes and not on
    voids, which is the exact inversion this pair of checks exists to undo.
    """
    # A CALLER THAT KNOWS OVERRIDES THE INFERENCE. Stage F makes nothing but void plates, so
    # measuring to find out is a guess at a settled fact. On 2026-08-05 that guess was wrong by
    # 0.0003: a tightly-framed holoblack measured pure_black 0.2997 against the 0.30 threshold, was
    # called a scene, and all three void-only checks silently skipped a real void plate. The
    # mechanism is framing, not lighting: a tight shot leaves less black in frame, so a threshold
    # calibrated on wider plates does not hold at the top of the framing range.
    #
    # Stage D still INFERS, and must, because D genuinely makes both: its slots carry
    # void-compatible looks alongside scenes.
    if declared:
        return True
    return pl["pure_black"] > VOID_PURE and pl["far_lit"] < VOID_FARLIT


def plate(sub: np.ndarray, box: tuple[int, int, int, int]) -> dict:
    """Light and colour, measured on the CROP that ships and around the face box inside it.

    Returns the two halves of the void test, pure_black (dark) and far_lit (empty); bg_black, which
    is how dark it looks and is now reported for context only because it decided this wrong for
    three versions running; face_lit (fraction of her face box above a readable luminance); and the
    saturation/hue of the brightest coloured pixels hugging her head and shoulders, which on a void
    plate is the rim light and nothing else.
    """
    a, b, c, d = box
    lum = 0.299 * sub[:, :, 0] + 0.587 * sub[:, :, 1] + 0.114 * sub[:, :, 2]
    fp = lum[b:d, a:c]
    out = {"pure_black": round(float((lum < 8).mean()), 4),
           "bg_black": round(float((lum < 25).mean()), 4),
           "face_lit": round(float((fp > 60).mean()), 4) if fp.size else 0.0,
           "far_lit": 0.0, "rim_sat": 0.0, "rim_hue": 0.0,
           "torso_lum": 255.0, "torso_chroma": 255.0}

    # FAR FROM HER: everything outside a column 2.5 face-widths either side of her face centre.
    # Chest-up framing puts her body inside that column, so what is left is background. When she
    # fills the frame there is barely any of it, and too few pixels to trust; that IS the void-like
    # case, so fall through with far_lit at 0 and let the darkness half decide.
    fw, fcx = c - a, (a + c) / 2.0
    far = np.ones(lum.shape, bool)
    far[:, max(0, int(fcx - 2.5 * fw)):min(lum.shape[1], int(fcx + 2.5 * fw))] = False
    if far.sum() >= 500:
        out["far_lit"] = round(float((lum[far] > 60).mean()), 4)

    # THE GARMENT BAND: below her chin, centred on her, one face-width wide. On the chest-up
    # framing the floors enforce, that region is torso and nothing else. Reported always, judged
    # only on voids, because a dark garment in a lit SCENE has the room around it to separate.
    fh = d - b
    ty0 = min(sub.shape[0] - 1, d + int(fh * 0.55))
    ty1 = min(sub.shape[0], d + int(fh * 1.8))
    tx0 = max(0, int(fcx - fw / 2))
    tx1 = min(sub.shape[1], int(fcx + fw / 2))
    gb = sub[ty0:ty1, tx0:tx1].astype(np.float32)
    if gb.size >= 600:
        out["torso_lum"] = round(float(np.median(lum[ty0:ty1, tx0:tx1])), 1)
        out["torso_chroma"] = round(float(np.median(gb.max(axis=2) - gb.min(axis=2))), 1)
    fh, fw = d - b, c - a
    ry0, ry1 = max(0, b - int(fh * 0.5)), min(sub.shape[0], d + int(fh * 1.2))
    rx0, rx1 = max(0, a - fw), min(sub.shape[1], c + fw)
    band, bl = sub[ry0:ry1, rx0:rx1].astype(np.float32) / 255.0, lum[ry0:ry1, rx0:rx1]
    keep = np.ones(bl.shape, bool)
    keep[b - ry0:d - ry0, a - rx0:c - rx0] = False    # her face is skin, not rim
    bright = keep & (bl > max(60.0, float(np.percentile(bl, 90))))
    if bright.sum() > 20:
        px = band[bright]
        mx, mn = px.max(axis=1), px.min(axis=1)
        sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
        i = int(np.argmax(sat))
        out["rim_sat"] = round(float(sat[i]), 4)
        out["rim_hue"] = round(float(colorsys.rgb_to_hsv(*px[i])[0] * 360.0), 1)
    return out


def judge(path: Path, aspect: float, frames: int, top_margin: float,
          centre_tol: float = 0.15, face_floor: float = 0.16,
          declared_void: bool = False) -> dict:
    times = [1.0, 4.0, 8.0][:max(1, frames)]
    findings, checked, centres, faces_h, plates = [], 0, [], [], []
    for t in times:
        try:
            img = grab(path, t)
        except Exception:
            continue
        h, w = img.shape[:2]
        faces = app().get(img[:, :, ::-1])       # detector wants BGR
        if not faces:
            continue
        checked += 1
        f = max(faces, key=lambda z: (z.bbox[2] - z.bbox[0]) * (z.bbox[3] - z.bbox[1]))
        fx0, fy0, fx1, fy1 = (float(v) for v in f.bbox)
        x0, y0, x1, y1 = crop_rect(h, w, aspect)
        # Hair and crown live above the detected box, so the top edge needs headroom.
        head_top = fy0 - (fy1 - fy0) * top_margin
        if head_top < y0:
            findings.append(f"t={t}s HEAD: crop starts at y={y0} but her head reaches y={head_top:.0f}")
        if fx0 < x0:
            findings.append(f"t={t}s BODY LEFT: crop starts at x={x0} but her face reaches x={fx0:.0f}")
        if fx1 > x1:
            findings.append(f"t={t}s BODY RIGHT: crop ends at x={x1} but her face reaches x={fx1:.0f}")
        # bottom deliberately unchecked: the author's rule says that is the safe edge

        # ZOOM. Shot size, measured against the crop that actually ships rather than the source
        # frame, so a landscape still is judged on the 768x768 HeyGen keeps and not on the 304px
        # per side it throws away. Floor is 0.16, read off his own golden set; see the module
        # docstring for the derivation and for the two metrics that lost to this one.
        fh = (fy1 - fy0) / max(1.0, float(y1 - y0))
        faces_h.append(fh)

        # ORIENTATION. A three-quarter profile still gives the detector a face box, so every other
        # check here passes one; the still the author named as facing away was caught on 2026-08-04 only
        # because a person turned toward a laptop also happens to sit off-centre. Centre that same
        # profile and it would have shipped.
        pose = getattr(f, "pose", None)
        if pose is not None and len(pose) >= 2 and abs(float(pose[1])) > YAW_MAX:
            findings.append(
                f"t={t}s TURNED AWAY: her head yaw is {float(pose[1]):+.1f} degrees, past the "
                f"{YAW_MAX:.0f} limit. The widest turn in his whole golden set is 33.3, so this is "
                f"outside anything he has kept; re-roll facing the camera")

        # LIGHT AND COLOUR, on the crop that ships. Both checks below are VOID-ONLY by design; see
        # the constants at the top of this file for why a flat rule throws away clips he loves.
        sub = img[y0:y1, x0:x1]
        pl = plate(sub, (int(max(0, fx0 - x0)), int(max(0, fy0 - y0)),
                         int(min(sub.shape[1], fx1 - x0)), int(min(sub.shape[0], fy1 - y0))))
        plates.append({"t": t, **pl})
        if is_void(pl, declared_void):
            if pl["rim_sat"] > RIM_SAT and not (RIM_WARM[0] <= pl["rim_hue"] <= RIM_WARM[1]):
                findings.append(
                    f"t={t}s COLD RIM ON A VOID: the rim light is hue {pl['rim_hue']:.0f} at "
                    f"saturation {pl['rim_sat']:.2f}, outside the warm {RIM_WARM[0]:.0f} to "
                    f"{RIM_WARM[1]:.0f} band. Every rim in his void goldens is warm; re-roll with "
                    f"warm or neutral rim wording")
            if pl["face_lit"] < LIT_MIN:
                findings.append(
                    f"t={t}s UNDER-LIT ON A VOID: only {pl['face_lit']:.2f} of her face reads above "
                    f"the readable floor, under {LIT_MIN:.2f}. The dimmest void he has kept lights "
                    f"0.71 of her face; she is lost in the black here, re-roll brighter")
            if pl["torso_lum"] < TORSO_LUM_MIN and pl["torso_chroma"] < TORSO_CHROMA_MIN:
                findings.append(
                    f"t={t}s GARMENT LOST IN THE VOID: her top reads at luminance "
                    f"{pl['torso_lum']:.0f} with chroma {pl['torso_chroma']:.0f}, under the "
                    f"{TORSO_LUM_MIN:.0f} brightness floor AND the {TORSO_CHROMA_MIN:.0f} colour "
                    f"floor. A neutral this dark vanishes against the black, so the lenticular has "
                    f"no body to give parallax. Re-roll lighter, or in a clear colour such as navy, "
                    f"burgundy or deep green, which reads even when dark")
        if fh < face_floor:
            findings.append(
                f"t={t}s ZOOMED OUT: her face is {fh:.3f} of the frame height, under the {face_floor:.3f} "
                f"floor, read off the 93 videos in his the golden-set album album. "
                f"She reads small in the frame; re-roll closer")

        # OFF-CENTRE lived here from 2026-08-03 to 2026-08-04 and has MOVED to body_guard.py.
        # It is not gone, it is owned in one place now. This version measured her FACE box; the
        # one that shipped measures her SILHOUETTE, which is the correct organ for the defect
        # (on both stills the author rejected, her face sat comfortably inside the crop while her hair
        # and shoulder left the frame). Over 44 shipped clips the two agreed on every single clip,
        # so this was pure duplication rather than a second opinion, and a duplicate with a
        # different tolerance (0.15 here against 0.12 there) is a disagreement waiting to happen.
        # the author: "just keep the one that works." The offset is still reported below for diagnosis.
        span = max(1.0, float(x1 - x0))
        offset = ((fx0 + fx1) / 2.0 - x0) / span - 0.5
        centres.append(offset)
    # WHICH checks fired, not just that something did. The verdict was the single label CROPS_HER
    # until 2026-08-05, from when this file had two checks and a rejection could only mean a cut.
    # It now has five, so that label was wrong for four of them, and on 2026-08-05 it told the author a
    # clip had been cropped when it was actually under-lit. A caller cannot report the real reason
    # if the payload never carries it, so the reason ships here.
    reasons = sorted({f.split(": ", 1)[0].split("s ", 1)[-1].strip() for f in findings})
    return {"checked_frames": checked, "findings": findings,
            "reasons": reasons,
            "centre_offsets": [round(c, 3) for c in centres],
            "face_heights": [round(f, 4) for f in faces_h],
            "face_floor": face_floor,
            "plates": plates,
            "verdict": "UNKNOWN" if checked == 0 else ("REJECT" if findings else "CLEAN")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--aspect", type=float, default=ASPECT)
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--top-margin", type=float, default=0.06,
                    help="fraction of face height treated as hair/crown above the detected box")
    ap.add_argument("--centre-tol", type=float, default=0.15,
                    help="how far off centre she may sit in the crop, as a fraction of crop width. "
                         "0.15 passes the 0.052 sibling and fails the 0.241 look the author rejected")
    ap.add_argument("--face-floor", type=float, default=0.16,
                    help="minimum face height as a fraction of crop height. 0.16 sits in the "
                         "empty band below the the golden-set album album, whose 5th percentile is 0.169")
    ap.add_argument("--void", action="store_true",
                    help="declare this still a void plate rather than inferring it. For a caller "
                         "that KNOWS: stage F makes only voids. Inference stays the default, and "
                         "stage D must keep it, since D makes both.")
    ap.add_argument("--look-id", default=None,
                    help="HeyGen look id this still belongs to. On a CLEAN verdict ONLY, records a "
                         "pass under state/zoom-gate/, which enforce-crop-gate-on-render.sh requires "
                         "before it will let the paid render through. Written HERE, by the "
                         "measurement, so it cannot be produced without running and passing")
    a = ap.parse_args()
    r = judge(Path(a.target), a.aspect, a.frames, a.top_margin, a.centre_tol, a.face_floor,
              declared_void=a.void)
    if a.look_id and r["verdict"] == "CLEAN":
        d = Path(__file__).resolve().parents[1] / "state" / "zoom-gate"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{a.look_id}.json").write_text(json.dumps(
            {"look_id": a.look_id, "target": str(Path(a.target).resolve()),
             "aspect": a.aspect, **r}))
    # JSON to stdout ONLY. InsightFace prints its model-loading banner to stdout on import, so a
    # caller doing `crop_guard.py x | jq` gets a parse error on the banner, not on the result.
    # Callers should read the LAST line; this keeps that line clean and single.
    print(json.dumps(r))
    # CROPS_HER is still honoured as an exit-code key so an older caller pinned to it cannot
    # silently start returning 1 (an infra error) for what is really a rejection.
    return {"CLEAN": 0, "REJECT": 2, "CROPS_HER": 2}.get(r["verdict"], 1)


if __name__ == "__main__":
    raise SystemExit(main())
