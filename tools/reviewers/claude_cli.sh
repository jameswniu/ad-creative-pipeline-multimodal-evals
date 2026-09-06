#!/bin/bash
# Reference reviewer for tools/pii_llm_review.sh, backed by the Claude Code CLI.
#
# Chosen as the default seat 2026-07-29, for two reasons in this order:
#   1. AUTH SHAPE. It runs on the operator's OAuth subscription. A privacy
#      gate that bills per call invites exactly the wrong economy: every run
#      has a marginal price, so the operator is nudged to run it less. The
#      gate must be free to run every commit, or it will not be run every
#      commit.
#   2. It is a reading model, not a routing model. The judgement layer's whole
#      purpose is what regex cannot see, which is a reading task.
#
# Two properties added 2026-09-05, after a 38-chunk commit failed closed twice
# on one transient reviewer error each time, a different chunk each run.
#   LEAN. A judge detaches from identity: no settings, no tools, no MCP, no
#      memory, only the prompt and a one-line system prompt. A default
#      headless call boots the operator's whole environment before it reads
#      a single line, which is both the wrong reviewer and the slow one.
#   RETRY. Three attempts with a short backoff before the chunk is reported
#      unavailable. An unreachable reviewer that answers on the second try has
#      read the content; only a reviewer that never answers has not.
#
# Contract (see pii_llm_review.sh header): argv[1] is the prompt; stdout must
# carry a JSON object containing routing_decision and rationale.
command -v claude >/dev/null 2>&1 || {
  echo "claude CLI not found; install it or set PII_LLM_CMD to another reviewer" >&2
  exit 1
}
# Cleared so the CLI behaves identically whether this gate runs from a plain
# terminal or from inside an agent session that sets it.
unset CLAUDECODE
PROMPT="Respond with ONLY a JSON object, no prose before or after, shaped exactly:
{\"routing_decision\": \"hold or research\", \"rationale\": \"<the FINDING lines, newline separated, or NO_FINDINGS>\"}
$1"
for attempt in 1 2 3; do
  if OUT=$(claude -p --model sonnet --max-turns 1 \
      --setting-sources "" --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --no-session-persistence --disable-slash-commands \
      --system-prompt "You are a privacy reviewer reading files before publication. Answer with one JSON object and nothing else." \
      "$PROMPT" 2>/dev/null) && [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
    exit 0
  fi
  sleep $((attempt * 5))
done
echo "reviewer failed after 3 attempts" >&2
exit 1
