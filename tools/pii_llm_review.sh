#!/usr/bin/env bash
# tools/pii_llm_review.sh - the judgement layer of the pre-publish PII gate.
#
# Run standalone:   bash tools/pii_llm_review.sh
# Staged only:      bash tools/pii_llm_review.sh --staged
# Explicit paths:   bash tools/pii_llm_review.sh path/one path/two
#
# EXIT CODES
#   0  the reviewer returned a clean verdict for every chunk
#   1  the reviewer flagged at least one chunk
#   2  the reviewer could not be reached, or returned something unparseable
#
# FAIL CLOSED, DELIBERATELY
#   Exit 2 is a FAILURE, not a pass. If the local model is down, the network is
#   out, the response does not parse, or the reviewer command cannot be found,
#   this script exits non-zero and the pre-commit hook stops the commit. An
#   unavailable reviewer means the content was never reviewed, and "never
#   reviewed" must never read the same as "reviewed and clean". Publication is
#   irreversible; a blocked commit costs a minute. If the model is genuinely
#   unavailable and the commit must go through anyway, that is a conscious human
#   decision and it is spelled PII_LLM_OVERRIDE=1, which is logged loudly in the
#   output so it shows up in any terminal scrollback or CI log.
#
# WHY THIS EXISTS ALONGSIDE tools/pii_scan.sh
#   The deterministic scanner catches shapes. It cannot catch:
#     - a third party named in ordinary prose, with no roster entry
#     - a daily routine, sleep window, or location inferable from wording
#     - confidential employer context that carries no ticket key or hostname
#     - a private message quoted as documentation
#     - a person made identifiable by the combination of two innocuous details
#   Those need a reader. This is the reader.
#
# WHY THE REVIEWER COMMAND IS NOT NAMED IN THIS FILE
#   This repository is public. Naming the specific local model tool here would
#   itself be a disclosure about the author's private toolchain, which is one of
#   the classes this gate exists to prevent. So the reviewer is resolved at run
#   time: PII_LLM_CMD if it is set, otherwise the first executable evaluator
#   skill found on this machine. Set PII_LLM_CMD explicitly in CI or on any
#   machine where discovery should not be guessed at.
#
#   The reviewer contract is minimal, so any model wrapper can satisfy it:
#     - it is invoked as:  "$PII_LLM_CMD" "<prompt text>"
#     - it prints JSON on stdout containing a "routing_decision" field
#     - a decision of "hold" or "act" means FLAGGED; anything else means clean
#     - a non-zero exit, empty output, or missing field means UNAVAILABLE

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Bytes of file content per reviewer call. Small enough that the model reads
# every line rather than skimming, large enough that a whole short file lands in
# one chunk and keeps its context.
CHUNK_BYTES="${PII_LLM_CHUNK_BYTES:-12000}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/pii_llm.XXXXXX")" || exit 2
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ---------------------------------------------------------------------------
# Resolve the reviewer command
# ---------------------------------------------------------------------------
resolve_reviewer() {
  if [ -n "${PII_LLM_CMD:-}" ]; then
    if [ -x "$PII_LLM_CMD" ] || command -v "$PII_LLM_CMD" >/dev/null 2>&1; then
      printf '%s' "$PII_LLM_CMD"; return 0
    fi
    return 1
  fi
  # Default seat: the in-repo Claude CLI wrapper, which runs on the
  # operator's OAuth subscription. Deliberately ahead of machine-local
  # discovery: a per-call-billed reviewer prices every run of a gate that
  # only works if it is free to run every time.
  if [ -x "$SCRIPT_DIR/reviewers/claude_cli.sh" ] && command -v claude >/dev/null 2>&1; then
    printf '%s' "$SCRIPT_DIR/reviewers/claude_cli.sh"; return 0
  fi
  local cand
  for cand in "$HOME"/.local/share/pii-review/*.sh; do
    [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

REVIEWER="$(resolve_reviewer || true)"
if [ -z "$REVIEWER" ]; then
  echo "=== pii_llm_review ==="
  echo "UNAVAILABLE: no reviewer command found."
  echo "Set PII_LLM_CMD to an executable that takes a prompt as argv[1] and"
  echo "prints JSON containing a routing_decision field."
  if [ "${PII_LLM_OVERRIDE:-0}" = "1" ]; then
    echo "PII_LLM_OVERRIDE=1: a human is knowingly publishing WITHOUT an LLM review."
    exit 0
  fi
  echo "RESULT: FAIL CLOSED. Not reviewed is not the same as clean."
  exit 2
fi

# ---------------------------------------------------------------------------
# Collect the content to review
# ---------------------------------------------------------------------------
MODE="tree"
EXPLICIT=()
for arg in "$@"; do
  case "$arg" in
    --staged) MODE="staged" ;;
    --tree)   MODE="tree" ;;
    -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "pii_llm_review: unknown option $arg" >&2; exit 2 ;;
    *)  MODE="explicit"; EXPLICIT+=("$arg") ;;
  esac
done

FILELIST="$TMPDIR_RUN/files.lst"
case "$MODE" in
  staged)
    ( cd "$REPO_ROOT" && git diff --cached --name-only --diff-filter=ACMR 2>/dev/null ) \
      | while IFS= read -r rel; do
          [ -n "$rel" ] && [ -f "$REPO_ROOT/$rel" ] && printf '%s\n' "$REPO_ROOT/$rel"
        done > "$FILELIST"
    ;;
  explicit)
    printf '%s\n' "${EXPLICIT[@]}" > "$FILELIST"
    ;;
  tree)
    # The publication set, not the filesystem. This used to be a bare find,
    # and the reviewer promptly flagged the gitignored local-only scanner
    # inputs (the third-party name roster and project-word list), which hold
    # exactly the content they exist to detect and are ignored precisely so
    # they can never ship. Reviewing them was scope error: the question this
    # tool answers is "is what CAN BE PUBLISHED clean", and ignored files
    # cannot be published. Tracked + untracked-but-not-ignored is that set.
    # The .gitignore wall those files depend on is asserted by the
    # deterministic scanner, so a gitignore regression fails the other layer.
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      ( cd "$REPO_ROOT" && { git ls-files; git ls-files --others --exclude-standard; } ) \
        | sort -u | while IFS= read -r rel; do
            [ -n "$rel" ] && [ -f "$REPO_ROOT/$rel" ] && printf '%s\n' "$REPO_ROOT/$rel"
          done > "$FILELIST"
    else
      find "$REPO_ROOT" \
        -type d \( -name .git -o -name '.venv*' -o -name node_modules \
                   -o -name __pycache__ -o -name renders -o -name state \) -prune -o \
        -type f -print > "$FILELIST"
    fi
    ;;
esac

# Text only. Binary media is class 7 and belongs to the deterministic scanner,
# which reads embedded metadata with a real metadata reader.
TEXTLIST="$TMPDIR_RUN/text.lst"
: > "$TEXTLIST"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.png|*.jpg|*.jpeg|*.webp|*.gif|*.mp4|*.mov|*.webm|*.wav|*.mp3|*.hop|*.quilt|*.pdf) continue ;;
  esac
  grep -Iq . "$f" 2>/dev/null && printf '%s\n' "$f" >> "$TEXTLIST"
done < "$FILELIST"

N_FILES=$(wc -l < "$TEXTLIST" | tr -d ' ')
if [ "$N_FILES" -eq 0 ]; then
  echo "=== pii_llm_review ==="
  echo "nothing to review (mode=$MODE)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build chunks. Each chunk carries its file boundaries so the model can name a
# path in its rationale.
# ---------------------------------------------------------------------------
CHUNKDIR="$TMPDIR_RUN/chunks"
mkdir -p "$CHUNKDIR"
chunk_index=0
current="$CHUNKDIR/chunk.000"
: > "$current"
new_chunk() {
  chunk_index=$((chunk_index + 1))
  current="$(printf '%s/chunk.%03d' "$CHUNKDIR" "$chunk_index")"
  : > "$current"
}
while IFS= read -r f; do
  rel="${f#$REPO_ROOT/}"
  {
    printf '\n===== FILE: %s =====\n' "$rel"
    # Line numbers are included so the model can point at a line, and so its
    # output is comparable with the deterministic scanner's path:line output.
    cat -n "$f"
  } >> "$current"
  size=$(wc -c < "$current" | tr -d ' ')
  [ "$size" -ge "$CHUNK_BYTES" ] && new_chunk
done < "$TEXTLIST"
find "$CHUNKDIR" -type f -size 0 -delete 2>/dev/null
N_CHUNKS=$(find "$CHUNKDIR" -type f | wc -l | tr -d ' ')

# ---------------------------------------------------------------------------
# The prompt. Redesigned 2026-07-29 after the chunk-verdict version saturated,
# then REVISED THE SAME DAY after the first redesign failed its recall
# calibration: a seeded corpus carrying a named attorney with a quoted private
# instruction, a sleep-schedule line, and an employer trace came back with ONE
# low/low advisory and exit 0. Root cause: the prompt listed the human-
# dismissed classes and said "do not spend findings on them", which a triage-
# tier model generalized into a license to ignore adjacent real findings.
# Rule that survives: RECALL LIVES IN THE PROMPT, PRECISION LIVES IN THE
# POST-FILTER. The ledger is applied only after the model answers, and is
# never shown to it. Grounding is limited to two narrow facts that cannot
# explain away a third party.
#
# (Original redesign rationale, still true:)
# 11/11 then 12/12 chunks flagged with ~2 real findings (docs/PII-REVIEW.md).
#
# WHAT CHANGED, AND WHY IT IS NOT "LOOSENING THE PROMPT"
#   The posture is unchanged: when uncertain, the reviewer still reports. What
#   changed is the UNIT and the INFORMATION. A binary verdict over a 12KB chunk
#   meant one uncertain line held everything, and twelve chunks made a red run
#   a mathematical certainty; the verdict destroyed the very information a
#   human needed to triage. Now every concern is emitted as its own line with
#   severity and confidence, uncertainty is expressed as confidence=low rather
#   than as a chunk-wide hold, and the gate applies the threshold. Recall is
#   preserved; the saturation was precision destroyed by the output format.
#
#   Second change: GROUNDING. The old prompt withheld the most important fact,
#   that the reviewer is reading a self-published portfolio repository, so it
#   flagged the repo's own filenames as "internal tool names" and the byline
#   as a leak. It now receives the tracked-file manifest and the repo's
#   purpose. Giving the judge ground truth is not making it less cautious.
#
#   Third: human dismissals live in tools/pii_review_ledger.txt and are
#   filtered AFTER the model answers, deterministically, with a visible count.
#   The model is also shown the ledger so it stops spending attention there,
#   but suppression never depends on the model honouring an instruction.
#   (Deterministic mechanism over prompt compliance; that is this repo's
#   entire thesis, and it is also what the 14-of-15 vs 6-of-15 table in the
#   README measures.)
# ---------------------------------------------------------------------------
build_prompt() {
  local body="$1" manifest="$2"
  cat <<PROMPT_EOF
You are a pre-publication privacy reviewer. The text below is about to be
published in a PUBLIC repository, permanently and irreversibly. Your job is to
report anything that should not be published.

TWO NARROW FACTS, and only these two:
- The repository is a portfolio its author publishes deliberately under their
  own byline; the author's name in the README byline or LICENSE line is a
  decision, not a leak. This covers ONLY the byline and license. The author's
  name anywhere else, or any other person's name anywhere, is still a finding.
- A bare filename that appears in this tracked-file manifest is the repo
  documenting itself, not an internal codename. This covers ONLY the filename
  itself, never the surrounding prose:
${manifest}

REPORT EVERYTHING ELSE. You are the recall layer of a two-layer gate: a
deterministic filter downstream removes findings a human has already reviewed,
and it can only remove what you emit. A finding you swallow is unrecoverable;
a finding you emit at confidence=low costs a human one line of reading.
Uncertainty goes in the confidence field, NEVER into omission.

Judge ONLY what a pattern matcher cannot see. A separate deterministic scanner
already covers API keys, tokens, email addresses, IP addresses, hostnames,
UUIDs, hex identifiers, phone numbers, ticket keys, and clock times. Look for:

1. THIRD PARTY PEOPLE. Any human other than the author made identifiable: a
   name, handle, role-plus-context, a quoted message attributed to someone, a
   described interaction with a named colleague, lawyer, relative, or online
   commenter. Highest-risk category. A single given name counts when the
   surrounding text narrows it to one real person.
2. INFERABLE ROUTINE, PRESENCE, OR LOCATION of a real person: sleep or work
   schedule, travel, commute, neighbourhood, venue, home layout, or a
   combination of details that narrows to one household.
3. CONFIDENTIAL WORKPLACE MATERIAL: an employer named or made obvious,
   internal project names that are NOT in the manifest above, incidents,
   personnel matters, or anything plausibly under NDA.
4. PRIVATE CONVERSATION CONTENT: verbatim quotes of a private message written
   by someone OTHER than the author. When the authorship of a quote is not
   clear from the text alone, treat it as another person's and emit it.
5. FIRST PARTY personal data beyond the deliberate byline: finances, health,
   family, employment status, account state.
6. COMBINATION IDENTIFIERS: two innocuous details that together identify one
   person, household, or company.

OUTPUT FORMAT, one line per concern, no prose around them:
FINDING|<file>|<line>|<category 1-6>|<severity high/medium/low>|<confidence high/medium/low>|<short description, never reproducing a secret value>

severity = damage if published. confidence = how sure you are it is real.
Uncertain? EMIT the finding with confidence=low. Never suppress your own
finding, and never escalate confidence you do not have: the gate blocks on
high/high, a human reads everything else, so a dishonest high is a false
block and a dishonest low is a silent miss.

If there is genuinely nothing to report, emit exactly: NO_FINDINGS

Set routing_decision to "hold" if you emitted any FINDING line, otherwise
"research". Put the FINDING lines (or NO_FINDINGS) in rationale, newline
separated, nothing else.

--- BEGIN CONTENT UNDER REVIEW ---
${body}
--- END CONTENT UNDER REVIEW ---
PROMPT_EOF
}

# ---------------------------------------------------------------------------
# Review loop
# ---------------------------------------------------------------------------
echo "=== pii_llm_review ==="
echo "mode=$MODE  files=$N_FILES  chunks=$N_CHUNKS  reviewer=$(basename "$(dirname "$REVIEWER")")/$(basename "$REVIEWER")"
echo

# Grounding context, built once. Manifest capped so a huge repo cannot blow the
# prompt budget; the cap is stated in the prompt itself via the ellipsis line.
LEDGER_FILE="$SCRIPT_DIR/pii_review_ledger.txt"
MANIFEST="$( (cd "$REPO_ROOT" && git ls-files 2>/dev/null || find . -type f -not -path './.git/*') | sed 's/^/    /' | head -150 )"
[ "$( (cd "$REPO_ROOT" && git ls-files 2>/dev/null || true) | wc -l | tr -d ' ')" -gt 150 ] && MANIFEST="$MANIFEST
    ... (manifest truncated at 150 files)"

# ledger_match <file> <description> -> 0 and prints rule name when suppressed
ledger_match() {
  local ffile="$1" fdesc="$2" name fsub re reason
  [ -r "$LEDGER_FILE" ] || return 1
  # TAB-separated: the regex field contains "|" for alternation, and the
  # first version of this parser used IFS='|', truncating every such regex
  # at its first alternation. Caught by the offline unit test; the tab is
  # load-bearing.
  while IFS=$'\t' read -r name fsub re reason; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$re" ] || continue
    if [ "$fsub" != "*" ]; then
      case "$ffile" in *"$fsub"*) : ;; *) continue ;; esac
    fi
    if printf '%s' "$fdesc" | grep -qiE "$re" 2>/dev/null; then
      printf '%s' "$name"; return 0
    fi
  done < "$LEDGER_FILE"
  return 1
}

FLAGGED=0
UNAVAILABLE=0
BLOCKERS=0
ADVISORY=0
SUPPRESSED=0
VERDICTS="$TMPDIR_RUN/verdicts.txt"
FINDINGS_LOG="$TMPDIR_RUN/findings.txt"
SUPPRESSED_LOG="$TMPDIR_RUN/suppressed.txt"
: > "$VERDICTS"; : > "$FINDINGS_LOG"; : > "$SUPPRESSED_LOG"

for chunk in $(find "$CHUNKDIR" -type f | sort); do
  label="$(basename "$chunk")"
  files_in_chunk="$(grep -c '^===== FILE:' "$chunk" 2>/dev/null || echo 0)"
  prompt="$(build_prompt "$(cat "$chunk")" "$MANIFEST")"

  raw="$("$REVIEWER" "$prompt" 2>"$TMPDIR_RUN/$label.err")"
  rc=$?
  # One bounded retry. In the first full-tree calibration run, 13 of 14 chunks
  # reviewed fine and one transient CLI failure failed the whole run closed.
  # Fail-closed on a persistent outage is the design; fail-closed on a single
  # flaky call just prices the gate in operator patience. Exactly one retry,
  # so a real outage still fails closed one call later.
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    sleep 5
    raw="$("$REVIEWER" "$prompt" 2>>"$TMPDIR_RUN/$label.err")"
    rc=$?
  fi

  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    echo "$label: UNAVAILABLE (reviewer exit $rc)"
    sed -n '1,3p' "$TMPDIR_RUN/$label.err" 2>/dev/null | sed 's/^/    /'
    UNAVAILABLE=$((UNAVAILABLE + 1))
    continue
  fi

  # Tolerate a wrapper that prints prose around the JSON: take the last JSON
  # object in the output.
  json="$(printf '%s' "$raw" | tr -d '\000' | awk '/^[[:space:]]*\{/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}')"
  decision="$(printf '%s' "$json" | jq -r 'first(..|objects|.routing_decision? // empty | select(. != ""))' 2>/dev/null)"
  # first VALUE, not first LINE: a head -1 here once truncated multi-line
  # rationales to their first FINDING and silently discarded the rest, which
  # made three different reviewer models all appear to return exactly one
  # finding. The parser was the shredder; first() keeps newlines intact.
  rationale="$(printf '%s' "$json" | jq -r 'first(..|objects|.rationale? // empty | select(. != ""))' 2>/dev/null)"
  priority="$(printf '%s' "$json"  | jq -r 'first(..|objects|.priority? // empty  | select(. != ""))' 2>/dev/null)"

  if [ -z "$decision" ]; then
    echo "$label: UNAVAILABLE (no routing_decision in reviewer output)"
    UNAVAILABLE=$((UNAVAILABLE + 1))
    continue
  fi

  # Per-finding accounting. The chunk is no longer the decision unit: one
  # uncertain line used to hold 12KB of clean content, and with ~12 chunks a
  # red run was arithmetically guaranteed. Findings are parsed individually,
  # human-dismissed classes are filtered by the ledger (deterministically,
  # after the model answers), and only high-severity/high-confidence
  # survivors block. Everything else stays visible as advisory.
  chunk_find=0
  while IFS= read -r fline; do
    case "$fline" in FINDING\|*) : ;; *) continue ;; esac
    chunk_find=$((chunk_find + 1))
    ffile=$(printf '%s' "$fline" | cut -d'|' -f2)
    flineno=$(printf '%s' "$fline" | cut -d'|' -f3)
    fcat=$(printf '%s' "$fline" | cut -d'|' -f4)
    fsev=$(printf '%s' "$fline" | cut -d'|' -f5 | tr 'A-Z' 'a-z')
    fconf=$(printf '%s' "$fline" | cut -d'|' -f6 | tr 'A-Z' 'a-z')
    fdesc=$(printf '%s' "$fline" | cut -d'|' -f7-)
    if rule=$(ledger_match "$ffile" "$fdesc"); then
      SUPPRESSED=$((SUPPRESSED + 1))
      printf '%s\t%s\t%s:%s\t%s\n' "$rule" "$fcat" "$ffile" "$flineno" "$fdesc" >> "$SUPPRESSED_LOG"
      continue
    fi
    if [ "$fsev" = "high" ] && [ "$fconf" = "high" ]; then
      BLOCKERS=$((BLOCKERS + 1))
      printf 'BLOCK  %s:%s  cat%s sev=%s conf=%s  %s\n' "$ffile" "$flineno" "$fcat" "$fsev" "$fconf" "$fdesc" >> "$FINDINGS_LOG"
    else
      ADVISORY=$((ADVISORY + 1))
      printf 'ADVISE %s:%s  cat%s sev=%s conf=%s  %s\n' "$ffile" "$flineno" "$fcat" "$fsev" "$fconf" "$fdesc" >> "$FINDINGS_LOG"
    fi
  done <<FINDS_EOF
$(printf '%s\n' "$rationale")
FINDS_EOF

  # A hold with no parseable FINDING line means the model would not or could
  # not follow the format. That is not silently clean: it becomes one loud
  # advisory carrying the raw rationale, so a hidden real find still reaches
  # the human, while a formatting failure cannot block the commit by itself.
  if [ "$chunk_find" -eq 0 ] && { [ "$decision" = "hold" ] || [ "$decision" = "act" ]; }; then
    ADVISORY=$((ADVISORY + 1))
    printf 'ADVISE %s:-  unstructured hold, raw rationale follows\n    %s\n' "$label" "$rationale" >> "$FINDINGS_LOG"
  fi
  printf '%s: findings=%s (decision=%s files=%s)\n' "$label" "$chunk_find" "$decision" "$files_in_chunk"
  printf '%s\t%s\t%s\n' "$label" "$chunk_find" "$decision" >> "$VERDICTS"
done

echo
echo "totals: chunks=$N_CHUNKS blockers=$BLOCKERS advisory=$ADVISORY suppressed_by_ledger=$SUPPRESSED unavailable=$UNAVAILABLE"

if [ "$SUPPRESSED" -gt 0 ]; then
  echo
  echo "--- suppressed by ledger (human-reviewed classes, tools/pii_review_ledger.txt) ---"
  awk -F'\t' '{c[$1]++} END{for (r in c) printf "  %3d x %s\n", c[r], r}' "$SUPPRESSED_LOG" | sort -rn
fi

if [ -s "$FINDINGS_LOG" ]; then
  echo
  echo "--- findings ---"
  sed 's/^/  /' "$FINDINGS_LOG"
fi

if [ "$UNAVAILABLE" -gt 0 ]; then
  echo
  if [ "${PII_LLM_OVERRIDE:-0}" = "1" ]; then
    echo "PII_LLM_OVERRIDE=1: $UNAVAILABLE chunk(s) were NEVER REVIEWED and are being"
    echo "let through on a human decision. Record why."
  else
    echo "RESULT: FAIL CLOSED. $UNAVAILABLE chunk(s) could not be reviewed."
    echo "An unreachable reviewer means the content was not read. That is not a pass."
    echo "Fix the reviewer, or set PII_LLM_OVERRIDE=1 to publish without this layer."
    exit 2
  fi
fi

if [ "$BLOCKERS" -gt 0 ]; then
  echo
  echo "RESULT: FAIL. $BLOCKERS high-severity/high-confidence finding(s) survived the ledger."
  echo "Fix the content, or if a finding is a reviewed false alarm, add a NARROW rule"
  echo "to tools/pii_review_ledger.txt with its reason, in the same commit, so the"
  echo "dismissal is visible in the diff. Never widen an existing rule to make one go away."
  exit 1
fi

if [ "$ADVISORY" -gt 0 ]; then
  echo
  echo "RESULT: PASS WITH ADVISORIES. $ADVISORY finding(s) below the block threshold."
  echo "They are listed above and they do not block, but they were emitted by a reviewer"
  echo "told never to suppress its own findings. Read them before pushing."
  exit 0
fi

echo
echo "RESULT: PASS on LLM review."
echo "Run tools/pii_scan.sh for the deterministic patterns if you have not already."
exit 0
