#!/usr/bin/env python3
"""coherence_probe.py — temporal triple-coherence instrument (v1, graph-with-state).

WHAT IT MEASURES: the defect the eye catches as "robotic": motion that merely
co-occurs with the words instant-by-instant instead of living as a trajectory —
constant churn with no rest, no articulated onsets, bursts unanchored to prosody.
Pairwise-at-an-instant cannot see this; it is a temporal-triple property
(motion_t x words_t x motion_t+1), so the probe walks the clip as a graph:
nodes = speech events (SRT cue onsets + prosodic RMS peaks), edges = pairwise
axes, and a STATE dict carried node-to-node (motion regime, phase debt) supplies
the third leg. Scripted video means the future is known: every upcoming onset
comes from the SRT, so "actions lead the words" is a deterministic check.

Components and their CALIBRATION STATUS (26-take labeled matrix, 2026-07-25):
  rest_fraction   share of the speech window spent in sustained head-band rest
                  (runs >= 0.25s below threshold). CALIBRATED and gating: the r16
                  human anchor lands 0.116 at REST_LEVEL 0.38; takes I called
                  robotic sit low (smooth-beach 0.007, regen-beach 0.000) and my
                  tune-down round measurably raised it (smooth-bakery 0.065 ->
                  human-bakery 0.106). KNOWN CONFOUND: the head band is a fixed
                  crop, so moving backgrounds (surf, street bustle) leak motion
                  and depress rest on outdoor scenes; a face-tracked crop (the
                  Vision tracker instrument) is the fix. Interpret outdoor FLAGs
                  with the eye. Also: rest measures the constant-motion defect
                  ONLY — the rejected calm wave PASSES rest (0.11-0.15) because
                  it was rejected for framing/register, a different defect class.
  prosody_lock    share of motion bursts starting within +-0.5s of a speech
                  event. SATURATED in v1 (0.84-1.00 on every take: events are so
                  dense that any burst trivially locks). Printed, NOT gating.
  phase           per-event motion-onset timing vs its event. SATURATED in v1
                  (every take reads a uniform ~-0.45s "lead": the onset detector
                  finds the previous burst, not an event-tied onset). Needs
                  word-level alignment before it means anything. Printed, NOT
                  gating.
  continuous      events with no articulated onset because motion never rested
                  beforehand — the "always moving" tell, counted per node.

Verdict v1: FLAG iff rest_fraction < 0.10. Diagnostic only: the eye outranks;
this joins the gate as a pre-filter, never a verdict on taste.

Usage: coherence_probe.py <clip.mp4> <sidecar.srt> [--json] [--rest-only]
       --rest-only: clips with music beds (RMS peaks unusable); rest axis only.
Exit 0 PASS / 1 FLAG.
"""
import json
import re
import subprocess
import sys

import numpy as np

REST_MIN = 0.10          # human floor: below this the take reads constant-motion
REST_RUN_S = 0.25        # stillness must persist to count as rest
REST_LEVEL = 0.38        # rest threshold = this * p75(motion during speech); calibrated
                         # so the r16 human anchor lands in its eye-verified 0.10-0.17
                         # rest zone. Relative-to-own-p75 is deliberate: bursty human
                         # motion has range (bursts high, rests low), constant robotic
                         # motion has none, so it never dips below its own threshold.
BURST_LEVEL_PCT = 80     # motion burst = above this percentile ...
BURST_RUN_S = 0.15       # ... sustained at least this long
EVENT_WIN = (-0.80, 0.35)  # motion-onset search window around an event (s)
LATE_S = 0.08            # onset later than this after the event = LATE
PEAK_SEP_S = 0.35        # min separation between prosodic peaks
EVENT_DEDUPE_S = 0.15    # cue onset + RMS peak within this = one node


def clip_fps(path):
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=r_frame_rate", "-of", "json", path], capture_output=True, text=True)
    num, den = json.loads(probe.stdout)["streams"][0]["r_frame_rate"].split("/")
    return float(num) / float(den)


def content_band(path):
    """Detect the real content rows (letterbox padding is flat white). Returns (y0, ch, w, h).

    Measuring a fixed fraction of a letterboxed frame silently lands the band in
    static padding (the r6 episode: rest read 0.130/0.014 on padded frames, true
    content values were 0.086/0.132 — verdicts FLIPPED). Geometry is detected,
    never assumed."""
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                            "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
                           capture_output=True, text=True)
    w, h = (int(x) for x in probe.stdout.strip().split(","))
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", "5", "-i", path, "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"], capture_output=True).stdout
    fr = np.frombuffer(raw[: w * h], dtype=np.uint8).reshape(h, w)
    rows = np.where(fr.mean(axis=1) <= 235)[0]
    if len(rows) < h * 0.2:          # detection failed; fall back to full frame
        return 0, h, w, h
    return int(rows.min()), int(rows.max() - rows.min() + 1), w, h


def head_series(path):
    # head band (1:1 talking-head geometry) — position/gesture motion, not mouth;
    # placed in CONTENT coordinates so letterboxing cannot dilute or relocate it
    y0, ch, w, h = content_band(path)
    crop = f"crop={w // 3}:{ch // 5}:{w // 3}:{y0 + int(0.06 * ch)}"
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf",
           f"{crop},scale=160:96,format=gray",
           "-f", "rawvideo", "pipe:1"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    n = len(raw) // (160 * 96)
    fr = np.frombuffer(raw[: n * 160 * 96], dtype=np.uint8).reshape(n, 96, 160).astype(np.float32)
    return np.abs(np.diff(fr, axis=0)).mean(axis=(1, 2))


def audio_rms(path, sr=8000, hop=320):
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(sr),
           "-f", "s16le", "pipe:1"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    n = len(x) // hop
    if n == 0:
        return np.zeros(1), sr / hop
    rms = np.sqrt((x[: n * hop].reshape(n, hop) ** 2).mean(axis=1))
    return rms, sr / hop


def srt_spans(srt):
    ts = re.findall(r"(\d\d):(\d\d):(\d\d),(\d\d\d) --> (\d\d):(\d\d):(\d\d),(\d\d\d)", open(srt).read())
    return [(int(a[1]) * 60 + int(a[2]) + int(a[3]) / 1000,
             int(a[5]) * 60 + int(a[6]) + int(a[7]) / 1000) for a in ts]


def runs_above(mask, min_len):
    """Start indices and lengths of True runs of at least min_len samples."""
    out, i = [], 0
    while i < len(mask):
        if mask[i]:
            j = i
            while j < len(mask) and mask[j]:
                j += 1
            if j - i >= min_len:
                out.append((i, j - i))
            i = j
        else:
            i += 1
    return out


def main():
    # Positional args are read by index, so a bare invocation used to die on IndexError
    # instead of saying what it wanted. Every other probe here prints a usage line; this
    # one was the outlier, and a stack trace is a worse answer than a sentence.
    positional = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(positional) < 2:
        print("usage: coherence_probe.py CLIP.mp4 CUES.srt [--json] [--rest-only]",
              file=sys.stderr)
        return 2
    path, srt = positional[0], positional[1]
    as_json, rest_only = "--json" in sys.argv, "--rest-only" in sys.argv
    fps = clip_fps(path)
    m = head_series(path)
    tm = np.arange(len(m)) / fps
    spans = srt_spans(srt)
    if not spans:
        # corrupt sidecar (e.g. a saved AccessDenied XML from a hand-transcribed
        # signed URL) — fail loud, never probe against an empty speech map
        print(f"COHERENCE ERROR: no cues parsed from {srt} — corrupt or empty sidecar")
        sys.exit(2)
    s0, s_end = spans[0][0], spans[-1][1]
    speech = (tm >= s0) & (tm <= s_end)

    # --- rest axis (whole speech window; the settle tail would inflate it) ---
    level = REST_LEVEL * np.percentile(m[speech], 75)
    rest_runs = runs_above((m < level) & speech, int(REST_RUN_S * fps))
    rest_frac = sum(l for _, l in rest_runs) / max(1, speech.sum())

    # --- motion bursts ---
    b_level = np.percentile(m[speech], BURST_LEVEL_PCT)
    bursts = runs_above((m > b_level) & speech, int(BURST_RUN_S * fps))
    burst_starts = [tm[i] for i, _ in bursts]

    out = {"clip": path, "fps": round(fps, 2), "rest_fraction": round(float(rest_frac), 3),
           "rest_runs": len(rest_runs)}

    if not rest_only:
        # --- event nodes: SRT cue onsets + prosodic RMS peaks inside speech ---
        rms, rfps = audio_rms(path)
        tr = np.arange(len(rms)) / rfps
        voiced = np.zeros(len(rms), bool)
        for s, e in spans:
            voiced |= (tr >= s) & (tr <= e)
        thresh = np.percentile(rms[voiced], 65) if voiced.any() else rms.max()
        peaks, last = [], -1e9
        for i in range(1, len(rms) - 1):
            if voiced[i] and rms[i] >= thresh and rms[i] >= rms[i - 1] and rms[i] >= rms[i + 1] \
                    and tr[i] - last >= PEAK_SEP_S:
                peaks.append(tr[i]); last = tr[i]
        events = sorted(set([s for s, _ in spans]) | set(peaks))
        nodes = []
        for e in events:
            if nodes and e - nodes[-1] < EVENT_DEDUPE_S:
                continue
            nodes.append(e)

        # --- the state walk: graph nodes with carried state ---
        state = {"leads": 0, "lates": 0, "sync": 0, "continuous": 0, "miss": 0,
                 "phase_debt": 0.0, "phases": []}
        on_level = np.percentile(m[speech], 60)
        for e in nodes:
            lo, hi = e + EVENT_WIN[0], e + EVENT_WIN[1]
            w = (tm >= lo) & (tm <= hi)
            if not w.any():
                continue
            idx = np.where(w)[0]
            onset = None
            for i in idx:
                pre = m[max(0, i - int(0.2 * fps)): i]
                if m[i] > on_level and len(pre) and pre.mean() < on_level:
                    onset = tm[i]
                    break
            if onset is None:
                # no articulated onset: was she already moving through the window?
                if m[idx].mean() > on_level:
                    state["continuous"] += 1     # the constant-motion tell
                else:
                    state["miss"] += 1           # genuinely still (rest is fine)
                continue
            ph = onset - e
            state["phases"].append(round(ph, 3))
            if ph > LATE_S:
                state["lates"] += 1
                state["phase_debt"] += ph
            elif ph > -0.03:
                state["sync"] += 1
            else:
                state["leads"] += 1
        n_onsets = state["leads"] + state["lates"] + state["sync"]
        locked = sum(1 for b in burst_starts if any(abs(b - e) <= 0.5 for e in nodes))
        lock = locked / max(1, len(burst_starts))
        out.update({"events": len(nodes), "onsets": n_onsets, "leads": state["leads"],
                    "sync": state["sync"], "lates": state["lates"],
                    "continuous": state["continuous"], "still": state["miss"],
                    "phase_debt_s": round(state["phase_debt"], 2),
                    "mean_phase_s": round(float(np.mean(state["phases"])), 3) if state["phases"] else None,
                    "bursts": len(burst_starts), "prosody_lock": round(lock, 2)})
    # v1 verdict gates on rest ONLY: lock and phase saturated on the calibration
    # matrix (no separation between labeled-good and labeled-robotic takes), so
    # they print as exploratory diagnostics without gate power until rebuilt on
    # word-level alignment.
    out["verdict"] = "FLAG" if rest_frac < REST_MIN else "PASS"

    if as_json:
        print(json.dumps(out))
    else:
        core = f"COHERENCE {out['verdict']}: rest {out['rest_fraction']:.3f} (min {REST_MIN})"
        if not rest_only:
            core += (f", lock {out['prosody_lock']:.2f}, leads/sync/lates "
                     f"{out['leads']}/{out['sync']}/{out['lates']}, continuous {out['continuous']}, "
                     f"mean phase {out['mean_phase_s']}s, debt {out['phase_debt_s']}s")
        print(core)
    sys.exit(0 if out["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    # Propagate main's return code. Discarding it made the new usage guard exit 0, which
    # tells a caller the run succeeded while printing that it did not, the same shape of
    # silent-success failure the suite's own doctrine warns about.
    sys.exit(main())
