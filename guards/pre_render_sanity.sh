#!/bin/bash
# pre_render_sanity.sh - THIN SHIM ONLY, no logic lives here.
#
# The real gate is pipeline behavior and lives WITH THE PIPELINE so it ports to
# any runtime (a second machine, another agent, a cron job) when the pipeline
# directory is copied. This file exists only so the agent host enforces the same
# gate deterministically, on the tool call, before any paid render.
#
# THIS GUARD FAILS OPEN ON PURPOSE, WHICH IS NOT TRUE OF THE OTHER THREE.
#   If the gate is absent or has moved, this exits 0 and the render proceeds.
#   That is a deliberate trade, not an oversight: the pipeline owns the rule,
#   and a host shim that started making its own decisions would become a second,
#   divergent implementation of the gate. Two gates that disagree are worse than
#   one gate that is sometimes missing, because you can no longer tell which one
#   made any given call.
#
#   The trade is only defensible because the shim is 3 lines and does nothing
#   but locate and exec. The moment logic appears below, the reasoning above
#   stops applying and this must fail closed instead.
#
#   The other three guards in this directory fail open by ACCIDENT, which is a
#   different thing entirely. See docs/ENFORCEMENT.md.
GATE="${PROP_GATE:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)/prop_gate.sh}"
[ -x "$GATE" ] || exit 0
exec "$GATE" hook
