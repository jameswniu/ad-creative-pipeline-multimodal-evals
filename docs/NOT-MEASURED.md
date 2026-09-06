# Not measured

What this repository does not claim, and what it would take to claim it honestly.

This file exists because the fastest way to lose a technical reader is one unearned number. Everything below is a number that could have been written and was not.

## How to read this

Every entry has the same three parts, so you can skim the verdicts and stop where it matters:

- **The verdict.** Not claimed, partly retracted, or not explained.
- **What IS measured**, stated plainly, so the gap is visible rather than implied.
- **To claim it**, naming the specific work that would close the gap. If a section has no such line, the claim is not reachable from here at all, and that is said instead.

---

## Time saved

**Not claimed.** The pipeline runs end to end in a median of 33 minutes with nobody watching, across 4 timed runs.

That is a measurement of the pipeline. It is **not** a claim about time saved, because no human was ever measured doing the same work by hand. Without a baseline there is no saving, only a duration.

**To claim it:** a defined manual procedure producing comparable output, at least 5 timed human runs, and the same quality bar applied to both. The procedure and the bar are specified in [MANUAL-BASELINE.md](MANUAL-BASELINE.md); the 5 runs have not happened. "Saves 4 hours a day" would have been the easiest sentence in this repo to write and the easiest one to get caught on.

## Dollar cost

**Not claimed.** Daily render cost is 2 vendor credits, measured at 4 different clip lengths.

Credits are not dollars. The conversion depends on the plan, the tier, and whatever the vendor was charging that month, and the rate was never recorded at the time of the measurement. Back-filling today's price onto an older measurement would produce a number that looks precise and is not.

**To claim it:** record the plan and the credit-to-currency rate alongside each usage reading, at the time of reading.

## Reliability as a rate

**Not claimed.** The README says 4 of 7, 14 of 15, 0 of 7. It never says 57%, 93%, or 0%.

Every one of those denominators is small enough that the percentage would imply a precision the sample cannot support. n=7 with 4 successes has a 95% confidence interval spanning roughly 18% to 90%. Reporting "57% reliable" from that is not a summary, it is a fabrication with a decimal point.

**To claim it:** enough runs that the interval narrows to something worth printing. The counts are reported as counts on purpose until then.

## Quality of the output

**Not claimed.** Nine invariants score the output, each with a threshold derived from labelled pass and fail exemplars rather than typed by hand.

This measures agreement with the labelled set. It does not measure whether the output is good, whether a viewer would like it, or whether the invariants cover the ways it can fail. Ten earlier metric models were built and discarded because they inverted on contact with the labelled set, which is evidence the labels are doing real work, and also evidence that the space of plausible-but-wrong metrics here is large.

**To claim it:** labels from an independent editorial source.

## Generalization

**Not claimed.** One operator, one machine, one set of vendor accounts, one display device.

Nothing here has been run by a second person or on a second machine. The guards have known portability gaps, documented in [ENFORCEMENT.md](ENFORCEMENT.md), which is exactly the class of problem a second machine would surface immediately.

**To claim it:** a second operator on a second machine, reporting what broke. The portability gaps above are the predicted failures, so anything else that breaks is the interesting result.

## The parallelism speedup

**Partly retracted.** The benchmark is real: 229s to 89s, byte-identical output, n=1.

The **explanation** originally written for it was wrong. The gain was attributed to batched inference. Checking production afterward, the setting meant to run ten workers in parallel was not taking effect, and 4 of 6 production runs were executing at the serial rate. The measured speedup traces to a different mechanism than the one first documented, and the per-pass contribution of the credited batching is about 1.06x, not the 2.1x first claimed.

The number survived. The causal story did not. Both are left in the repo rather than quietly corrected, because the gap between them is the more useful artifact.

**To claim the mechanism:** ablate one factor at a time against the same input, rather than reasoning backwards from a single end-to-end timing.

## How much of the look library would fail the wardrobe check

**Not claimed.** Two looks were measured against the black matte, not the library. A dark top cleared the fill by 22 luma where the face cleared it by 134, so the torso dissolved; the replacement cream top cleared it by 171. That is n=2, and it is enough to establish that the failure is real and not enough to establish a rate.

The tempting sentence was "most of the library would fail this." The evidence for it is genuinely weak: the *names* of the 50 most recent looks lean heavily dark, carrying "in the Void" four times, "Rimmed" or "Rim-Lit" fourteen times, "on Black" twice, plus "of Shadow" and "Black Tee". A name is not a measurement. It is the art direction that was specified, which makes it a description of the prompts rather than of the pixels, and the one look whose name says "Cream Cable-Knit, Golden-Silver Rim-Lit **on Black**" would very likely pass while sounding like it fails.

**To claim it:** read the torso band of all 304 look previews, apply the same separation bar, and report the count with its denominator. That is one loop over an endpoint that already returns every preview URL, so the reason this is unmeasured is that the pattern was noticed after the run, not that it is hard.

The related structural point does not need the rate to be true: the fill colour and the wardrobe are one decision, and no probe in the suite knew that.

## Why the lip-sync figure moves

**Not explained.** Across a grid of three looks, three voice clones and three engine tiers, `lipsync_probe` reported dropped-onset rates from 19 to 43 percent with no clean association to any of the three variables.

Two causes were proposed with confidence and both were wrong. The first blamed the still, reasoning that the still is the animation seed. A control run then showed the low-scoring comparison clip had been rendered on a different engine entirely, so the comparison had never been like for like. The second blamed the engine. A third look on a third engine then read 43 percent again.

Two possibilities remain, and this repository cannot currently distinguish them:

1. The probe's 0.8-second response window is too tight for this voice's pacing, in which case the metric is mismeasuring a clip that is fine.
2. Every clip in the grid genuinely drops phrases at this rate, and the eye tolerates it because a viewer does not audit onsets.

The second is the uncomfortable one and it is not ruled out.

**To claim it:** frame-level annotation of mouth openings against audio onsets on a labelled clip. That is the same move that resolved the gesture-timing question after thirteen metrics found nothing: stop correlating and go describe the physics. Until then the figure is reported and does not gate.

## Known open bugs

Stated here rather than fixed silently before publishing:

1. The parallel worker setting does not take effect. 4 of 6 production runs measured at the serial rate.
2. Three of four guards fail open when a dependency is missing, and report success while doing it.
3. The depth speedup is attributed to the wrong mechanism, per above.
4. Nothing checks that the avatar is distinguishable from the background she is composited onto. Eleven probes score her face, her motion and her timing; the twelfth measures background detail, which is a property of the backdrop rather than of the contrast between her and it. A dark garment on a zero-luma fill passes every gate and ships a floating head.

None of these are fixed in this snapshot. A repo whose headline claim is "count attempts, not outcomes" would be a poor place to hide its own open findings.
