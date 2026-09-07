#!/usr/bin/env bash
# tools/ci_require_pii_secrets.sh - decide what a missing scanner secret means.
#
# WHY THIS IS A FILE AND NOT SIX LINES OF YAML
#   The workflow used to print "context: ABSENT, class 5 and 6 project words
#   will be SKIPPED" and then exit 0. So a run with no secrets configured at
#   all was a green check mark, on a repository whose whole point is that a
#   check announcing failure must not report success. A green tick that means
#   "three of the seven classes never ran" is the same defect the scanner
#   itself was written to stop, one layer up.
#
#   Inline YAML cannot be tested. This can, and tests/test_suite.py does, in
#   both directions, which is why the logic lives here and the workflow calls
#   it.
#
# THE POLICY, in the order it is evaluated
#   1. BOTH secrets present            -> armed, exit 0.
#   2. The run cannot read secrets at all (a pull request from a fork)
#                                      -> SKIPPED, exit 0. The check is
#      reported as skipped rather than passed, because a contributor who
#      structurally cannot hold the credential must not be handed a red check
#      they have no way to clear, and must not be handed a green one either.
#      The workflow ALSO carries an `if:` that keeps this step from running on
#      a fork at all, so the check renders as skipped in the UI. This branch
#      is the second wall, for the day somebody edits that condition.
#   3. The run targets the publication branch (a push to it, or a pull request
#      into it)                        -> FAIL, exit 1. This is the moment the
#      content becomes public, and an unarmed scan is not a scan.
#   4. Anything else, a push to a working branch -> WARN, exit 0. Not the
#      publication moment, and a red check on every intermediate push is how a
#      gate gets routed around.
#   5. The context could not be determined at all -> FAIL, exit 1. An unknown
#      state is not a safe state.
#
# ENVIRONMENT
#   PII_CONTEXT, PII_NAMES        the secret values, empty when unset
#   IS_FORK                       "true" when the head repo is not this repo
#   TARGET_BRANCH                 base_ref for a pull request, ref_name otherwise
#   PUBLICATION_BRANCH            the repository default branch
#   GITHUB_STEP_SUMMARY           optional, appended to when present

set -uo pipefail

CONTEXT_VALUE="${PII_CONTEXT:-}"
NAMES_VALUE="${PII_NAMES:-}"

# A secret pasted from a Windows editor or through a web form arrives with CRLF
# line endings, and the stray carriage return rides into whichever field ends
# the line: into the grep flags as `-i<CR>`, which grep rejects outright, or
# into the regex as a character that can never match. The workflow strips them
# when it materializes the files, and they are stripped here as well, so this
# gate and the scanner are judging the same bytes. Two normalizations that
# agree is the point; a gate validating input the scanner will not see is just
# a second opinion about a different file.
CONTEXT_VALUE="$(printf '%s' "$CONTEXT_VALUE" | tr -d '\r')"
NAMES_VALUE="$(printf '%s' "$NAMES_VALUE" | tr -d '\r')"
IS_FORK="${IS_FORK:-false}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
PUBLICATION_BRANCH="${PUBLICATION_BRANCH:-}"

# PRESENT IS NOT ARMED. A length test passes a secret holding nothing but the
# template's comment lines, and the scanner then parses zero rules out of it
# and marks those classes SKIPPED, so the check said armed while the classes it
# vouched for never ran. That is the same defect this file exists to close, one
# level further in. So both values are parsed HERE the way the scanner parses
# them, and a value that yields nothing usable counts as missing.
#
#   context: a rule is SEVERITY tab CLASS tab LABEL tab REGEX, with an optional
#            fifth grep-flags field. apply_rule_table reads those five with
#            IFS set to tab and skips any row whose regex field came out
#            empty, so a row with fewer than four tab-separated fields is not
#            a rule. Counting non-comment LINES instead of rules passed a
#            secret holding a bare word like `workplaceword`, or one whose
#            tabs had been flattened to spaces by a paste, and reported ARMED
#            while the scanner activated nothing at all.
#   names:   comments, blanks, and any line carrying a character outside
#            letters and spaces are dropped, at least one name must remain
# Both counters run the SCANNER'S OWN parse rather than an approximation of it,
# because an approximation is a second implementation and two implementations
# drift. An awk pass with a tab field separator counted
# `HIGH<tab>CLASS<tab><tab>regex` as one rule, while the scanner reads that line
# with IFS set to tab, where a run of tabs collapses to one separator, the
# regex field lands empty and the rule is skipped. One ordinary typo, an armed
# verdict, and nothing activated.
# Prints two numbers, usable rules and rejected patterns. It prints them rather
# than setting variables because it is called in a command substitution, which
# is a subshell, and a count assigned in a subshell is a count thrown away.
# THE STRUCTURE IS JUDGED WITH A PARSER THAT KEEPS EMPTY COLUMNS, and only
# then are the fields judged. Reading the row the way the scanner reads it, with
# IFS set to tab, is not enough on its own, because that read COLLAPSES a run of
# tabs: a row with an empty label,
#     HIGH <tab> CLASS5 <tab> <tab> \bzebra\b <tab> -i
# arrives as label `\bzebra\b` and regex `-i`, which is a valid severity, a
# valid class, a non-empty label and a pattern grep accepts. Every field test
# passes, the verdict is ARMED, and the scanner is hunting for the string `-i`
# while `zebra` walks out of the repository.
#
# So awk splits the row with a true tab separator, which preserves empty
# columns, and a row is usable only when it has four or five columns with none
# of the first four empty. Under that condition the collapsing read cannot
# disagree with this one, because there is no empty column left to collapse.
# The two parsers are made to agree by construction rather than by hope.
#
#   severity  the report loops over BLOCKER HIGH MEDIUM LOW and counts with a
#             literal grep, so a rule written `High` records a hit that is
#             never counted, never displayed and never fails the run. An
#             invisible finding is worse than no rule at all: the operator
#             believes the term is guarded.
#   class and label  land in the colon-delimited output line, so a colon in
#             either breaks the line the report is parsed from. The scanner
#             already refuses a path carrying a colon for this reason.
#   label     is also the allowlist key, so an empty one is a finding no
#             reviewer can suppress except by deleting the rule.
#   flags     are restricted to what preserves the output contract, not merely
#             to what grep accepts. grep takes -q, -l and -h without complaint
#             and each one strips the path and line prefix run_rule reads the
#             finding out of, so the rule matches and reports nothing, which is
#             the quietest possible failure. The field exists for one purpose.
count_context_rules() {
  local line rest flags re rc n=0 bad=0
  while IFS= read -r line; do
    case "$line" in
      BAD) bad=$((bad + 1)); continue ;;
      OK*) ;;
      *) continue ;;
    esac
    rest="${line#OK }"
    flags="${rest%%$'\t'*}"
    re="${rest#*$'\t'}"
    # The regex is run through the SAME invocation run_rule makes, flags
    # included and unquoted, because a validator that runs a tidier command
    # than the executor is answering a question nobody asked. grep exits 0 on a
    # match and 1 on no match; anything higher is the engine refusing the
    # pattern, and the scanner discards that complaint where this cannot.
    # shellcheck disable=SC2086
    printf '' | grep -a -E $flags -e "$re" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -gt 1 ]; then bad=$((bad + 1)); else n=$((n + 1)); fi
  done < <(printf '%s\n' "$CONTEXT_VALUE" | awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if (NF < 4 || NF > 5)                         { print "BAD"; next }
      if ($1 == "" || $2 == "" || $3 == "" || $4 == "") { print "BAD"; next }
      if ($1 != "BLOCKER" && $1 != "HIGH" && $1 != "MEDIUM" && $1 != "LOW") { print "BAD"; next }
      if (index($2, ":") || index($3, ":"))         { print "BAD"; next }
      f = (NF == 5 ? $5 : "")
      if (f != "" && f != "-i")                     { print "BAD"; next }
      print "OK " f "\t" $4
    }')
  printf '%s %s' "$n" "$bad"
}
# Prints usable names and rejected entries, for the same reason as above. A
# roster is not armed just because ONE name in it survived: an entry the
# scanner refuses is a third party the operator believes is guarded and is not,
# which is worse than never having listed them.
count_roster_names() {
  local n=0 bad=0 line
  while IFS= read -r line; do
    # The scanner's own tests, in its own order.
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *[!A-Za-z\ \'-]*) bad=$((bad + 1)); continue ;; esac
    # And one the scanner does not make: a line of nothing but spaces passes
    # its tests and becomes a degenerate roster entry. It loads, so the scanner
    # does not call the check skipped, and it identifies nobody.
    case "$line" in *[A-Za-z]*) ;; *) bad=$((bad + 1)); continue ;; esac
    n=$((n + 1))
  done <<< "$NAMES_VALUE"
  printf '%s %s' "$n" "$bad"
}

CONTEXT_PARSE="$(count_context_rules)"
CONTEXT_RULES="${CONTEXT_PARSE%% *}"
BAD_REGEX="${CONTEXT_PARSE##* }"
ROSTER_PARSE="$(count_roster_names)"
ROSTER_NAMES="${ROSTER_PARSE%% *}"
BAD_NAMES="${ROSTER_PARSE##* }"
: "${CONTEXT_RULES:=0}" "${BAD_REGEX:=0}" "${ROSTER_NAMES:=0}" "${BAD_NAMES:=0}"

MISSING=""
UNUSABLE=""
if [ -z "$CONTEXT_VALUE" ]; then
  MISSING="PII_CONTEXT"
elif [ "$CONTEXT_RULES" -eq 0 ]; then
  MISSING="PII_CONTEXT"
  UNUSABLE="PII_CONTEXT is set but parses to zero rules (a rule is four TAB separated fields)"
fi
# A rejected pattern is reported even when other rules survive, because the
# operator wrote a rule and it is not running, and nothing else would say so.
if [ "$BAD_REGEX" -gt 0 ]; then
  UNUSABLE="${UNUSABLE:+$UNUSABLE, }$BAD_REGEX context rule(s) the scanner cannot execute (a row with fewer than four TAB separated fields, a severity outside BLOCKER HIGH MEDIUM LOW, an empty or colon-bearing class or label, a flags field other than -i, or a pattern the regex engine rejects)"
  MISSING="${MISSING:-PII_CONTEXT}"
fi
if [ -z "$NAMES_VALUE" ]; then
  MISSING="${MISSING:+$MISSING and }PII_NAMES"
elif [ "$ROSTER_NAMES" -eq 0 ]; then
  MISSING="${MISSING:+$MISSING and }PII_NAMES"
  UNUSABLE="${UNUSABLE:+$UNUSABLE, }PII_NAMES is set but parses to zero names"
fi
# Same reasoning as the rejected rules above. One usable name does not arm a
# roster whose other entries the scanner throws away.
if [ "$BAD_NAMES" -gt 0 ]; then
  UNUSABLE="${UNUSABLE:+$UNUSABLE, }$BAD_NAMES roster entr(y/ies) the scanner refuses (a name may hold letters, spaces, hyphens and apostrophes, and nothing else)"
  MISSING="${MISSING:-PII_NAMES}"
fi

# Written to the job summary as well as stdout when the summary exists, because
# log output nobody expands is not a report.
say_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

if [ -z "$MISSING" ]; then
  echo "ARMED: $CONTEXT_RULES project rule(s) and $ROSTER_NAMES roster name(s) parsed,"
  echo "so all seven classes run."
  say_summary "PII context: **armed**, $CONTEXT_RULES rules and $ROSTER_NAMES names parsed."
  exit 0
fi

# Said once, ahead of whichever verdict follows, because "set but useless" is a
# different repair from "not set" and the operator needs to know which they have.
if [ -n "$UNUSABLE" ]; then
  echo "NOTE: $UNUSABLE."
fi

if [ "$IS_FORK" = "true" ]; then
  echo "SKIPPED: this is a pull request from a fork, which cannot read repository"
  echo "secrets. Class 4 third-party names and the class 5 and 6 project words did"
  echo "NOT run. This is reported as skipped, not as a pass. A maintainer must run"
  echo "the armed scan before this branch reaches the publication branch."
  echo "::notice title=PII context SKIPPED::A fork pull request cannot read the scanner secrets, so classes 4, 5 and 6 did not run. This check is skipped, not passed."
  say_summary "PII context: **SKIPPED** on a fork pull request. Classes 4, 5 and 6 did not run. Skipped is not passed."
  exit 0
fi

if [ -z "$TARGET_BRANCH" ] || [ -z "$PUBLICATION_BRANCH" ]; then
  echo "FAIL: $MISSING not armed, and the branch context could not be determined"
  echo "(TARGET_BRANCH='$TARGET_BRANCH' PUBLICATION_BRANCH='$PUBLICATION_BRANCH')."
  echo "An unknown state is not a safe state, so this fails rather than warns."
  echo "::error title=PII context not armed::$MISSING is not armed and the branch context is unknown."
  say_summary "PII context: **FAILED**, $MISSING not armed and the branch context unknown."
  exit 1
fi

if [ "$TARGET_BRANCH" = "$PUBLICATION_BRANCH" ]; then
  echo "FAIL: $MISSING not armed on the publication branch '$PUBLICATION_BRANCH'."
  echo "Class 4 third-party names and the class 5 and 6 project words would be"
  echo "SKIPPED, and a skipped check is not a passing check. This job fails rather"
  echo "than report green on a scan that never examined three of its seven classes."
  echo "Set the PII_CONTEXT and PII_NAMES repository secrets."
  echo "::error title=PII context not armed::$MISSING is not armed, so classes 4, 5 and 6 cannot run on the publication branch."
  say_summary "PII context: **FAILED**, $MISSING not armed on \`$PUBLICATION_BRANCH\`."
  exit 1
fi

echo "WARNING: $MISSING not armed on working branch '$TARGET_BRANCH'."
echo "Classes 4, 5 and 6 are SKIPPED on this run. This is not the publication"
echo "branch, so it warns rather than fails, but the same state fails on"
echo "'$PUBLICATION_BRANCH'. Fix it before opening the pull request."
echo "::warning title=PII context not armed::$MISSING is not armed, so classes 4, 5 and 6 are skipped on this run."
say_summary "PII context: **skipped** on \`$TARGET_BRANCH\`, $MISSING not armed. The same state fails on \`$PUBLICATION_BRANCH\`."
exit 0
