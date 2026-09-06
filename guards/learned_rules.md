# learned_rules.md

The read-back leg of the prop gate's loop. `prop_gate.sh` splices the `## Learned`
section below into the probe text it hands the reviewing model, so a failure that
has already cost a render gets stated before the next one is judged rather than
rediscovered.

The write-back leg is `arrow_rejects.txt`, which records a specific look that was
rejected and why. That file is per-operator and is not committed; this one is, so
a clone has the rules even with no local history. Both were missing from the
published repo, which meant `prop_gate.sh selftest` failed on a fresh clone and
the loop the docs describe was inert. That is the defect this file closes.

Keep entries short and phrased as things to CHECK. Anything longer belongs in
`docs/EVALS.md`; this text is read by a model with a job to do.

## Learned

- **A prop the subject holds must be the thing the script says it is.** A generated
  look once put a plausible object in her hand that the narration never mentioned,
  and it read as a continuity error rather than a render fault.
- **Count the limbs and the fingers before approving a look.** These fail
  plausibly. An extra finger survives a glance and does not survive a viewer.
- **A held object must have a reason to be held.** If the script does not refer to
  it, and the pose does not explain it, treat it as a reject.
- **Text in frame is a reject unless the script asked for it.** Generated lettering
  is almost never spelled correctly and cannot be corrected after the render.
- **The background must be simple enough for the engine that freezes it.** For
  `avatar_iii` the whole backdrop becomes a photograph while only the subject
  animates, so detail behind her reads as dead. `probes/bg_detail.py` measures
  this and its bar is 5.5, derived from a labelled pass at 4.27 and a reject at 7.05.
- **A dark garment against a dark fill is one decision, not two.** Choosing the
  matte fill and choosing the wardrobe together decide whether the torso survives
  separation. This repository shipped a floating head before noticing that.
- **Do not infer a property of a look from a single rejection.** Two clips from one
  look, one accepted and one rejected, measured within 3 percent on every term.
  The per-render draw was the variable. Re-roll the same look instead.
