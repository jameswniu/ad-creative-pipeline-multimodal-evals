# The manual baseline

`NOT-MEASURED.md` sets three conditions before this repository may state a time saving. Two of them are specification work and are settled here. The third is a stopwatch and is not.

| | Condition | State |
|---|---|---|
| 1 | A defined manual procedure producing comparable output | **Defined below.** |
| 2 | At least 5 timed human runs of it | **Open.** Needs a person. |
| 3 | The same quality bar applied to both sides | **Defined below.** It is the existing gate set, unchanged. |

Until condition 2 is met, no page here states a time saving, and the before/after table stays built on mechanism.

## What the pipeline side already is

A median of 33 minutes end to end, unattended, across 4 timed runs. That number is a duration, not a saving. It becomes a saving only when the same output has been produced by hand and timed.

## The quality bar, for both sides

Comparable does not mean similar. Output from either side counts only if it clears the identical bar the pipeline already enforces:

- the 16 named gating thresholds in `probes/`, each bracketed by a labelled pass and a labelled reject
- the 4 guards, with the 3 that fail open treated as failures for the purpose of this study, not as passes
- the same clip length, the same aspect, and a 77-view quilt at the same tile resolution
- the identity allowlist honoured, so the presenter is the same approved look on both sides

A hand-made clip that a probe would have rejected does not count as a completed run. Neither does one that skipped the quilt. This is the condition that makes the two numbers mean the same thing, and it is the one most easily lost by accident.

## The manual procedure

One operator, working from the same brief and the same source assets the pipeline receives. The vendor tools stay the same. What changes is that every decision is made by eye rather than by threshold, and every wait is attended rather than scheduled.

Stages 1 through 4, authoring:

1. Write the script to the brief.
2. Produce the voice line from the approved clone.
3. Select the look from the identity allowlist.
4. Render the talking-head clip.

Stage 5 through 9, finishing:

5. Matte the presenter from the plate.
6. Review the take. Accept or re-render. **Log every re-render as part of the run.**
7. Obtain depth for the accepted take.
8. Build the 77-view quilt.
9. Confirm the result on the panel.

## Timing rules

These decide whether the resulting number is honest.

- **The clock starts** when the brief is handed over and **stops** when a quilt clears the bar above. Not when the first render finishes.
- **Attended waiting counts.** If the operator sits watching a render, that time is theirs. The pipeline's 33 minutes already includes its own waits.
- **Re-renders count.** Discarded takes are the largest expected difference between the two sides and excluding them would flatter the manual number.
- **Setup and teardown are excluded on both sides**, so the comparison is per clip and not per session.
- **Record each run separately.** Report the median across at least 5, alongside the range. A mean across a small n hides the re-render tail, which is the interesting part.

## What a result would license

Only a per-clip comparison, on this hardware, for this clip shape, with n stated beside it. Not a daily figure, not a headcount figure, and not an extrapolation to clip lengths never timed. Should the runs land close together, the honest conclusion may be that the saving is small and the real difference is that one side runs with nobody watching, which is already claimed and already measured.
