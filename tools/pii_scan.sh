#!/usr/bin/env bash
# tools/pii_scan.sh - deterministic pre-publish PII gate for this repository.
#
# Run standalone:   bash tools/pii_scan.sh
# Staged files:     bash tools/pii_scan.sh --staged   (reads the INDEX, not the tree)
# Explicit paths:   bash tools/pii_scan.sh path/one path/two
# Report only:      PII_SCAN_SOFT=1 bash tools/pii_scan.sh    (always exits 0)
#
# EXIT CODES
#   0  no BLOCKER and no HIGH finding
#   1  at least one BLOCKER or HIGH finding, publication must not proceed
#   2  the scanner could not run correctly (bad arguments, unusable file list)
#
# OUTPUT CONTRACT
#   One line per finding:  <path>:<line>:<CLASS>:<SEVERITY>:<label>
#   The matched text is NEVER printed. Only the location and the class are
#   emitted, because this output gets pasted into tickets and chat. Open the
#   file yourself to see the value.
#
# WHY TWO SCANNERS
#   Regex catches shapes: keys, ids, emails, hosts, paths, ticket keys, clock
#   times. Regex cannot catch a third party named in flowing prose, an inferable
#   daily routine described in words, or confidential context carrying no
#   keyword. That is tools/pii_llm_review.sh, which runs beside this one. The
#   pre-commit hook runs both because neither is sufficient alone.
#
# WHY IDENTIFYING WORDS ARE NOT IN THIS FILE
#   This file is tracked and will be public. A scanner that hardcodes the
#   employer name, private repo names, the author's city, or a colleague's name
#   leaks exactly what it is meant to prevent. So every project-specific string
#   is loaded at runtime from two local, gitignored inputs:
#       tools/pii_context.txt   one RULE per line, project-specific. A rule is
#                               SEVERITY tab CLASS tab LABEL tab REGEX, with an
#                               optional fifth grep-flags field. It is not a
#                               bare regex fragment; this line said it was, and
#                               a fragment loads as nothing at all.
#       tools/pii_names.txt     one "First Last" per line, third-party names
#   plus the person roster from a local shared library if one is installed.
#   When those inputs are missing the affected check is SKIPPED and a NOTE is
#   printed on stderr. A skipped check is not a passing check, and the summary
#   says so.
#
# SUPPRESSION
#   Two mechanisms, both visible in the diff:
#     1. an inline "pii-allow" marker anywhere on the offending line
#     2. a line in tools/pii_allowlist.txt of the form  <path-substring>|<label>
#   Suppressions are counted in the summary so they cannot hide.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/pii_allowlist.txt"
CONTEXT_FILE="${PII_CONTEXT_FILE:-$SCRIPT_DIR/pii_context.txt}"
NAMES_FILE="${PII_NAMES_FILE:-$SCRIPT_DIR/pii_names.txt}"
ROSTER_LIB="${PII_PATTERNS_LIB:-$HOME/claude-os/scripts/pii-patterns.sh}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/pii_scan.XXXXXX")" || exit 2
trap 'rm -rf "$TMPDIR_RUN"' EXIT
FILELIST="$TMPDIR_RUN/files.lst"
TEXTLIST="$TMPDIR_RUN/text.lst"
MEDIALIST="$TMPDIR_RUN/media.lst"
HITS="$TMPDIR_RUN/hits.lst"
: > "$HITS"

# Staged mode scans the INDEX, so the index blobs are written out here and read
# from here. This lives inside TMPDIR_RUN, so the EXIT trap above removes it
# along with everything else the run created.
STAGED_ROOT="$TMPDIR_RUN/staged"
# Staged submodule paths, held in memory rather than in a file. A submodule is
# index mode 160000 and carries no blob, so it is the one entry that is
# legitimately unreadable, and it is named here rather than inferred from an
# extraction failure. Nothing about the integrity check below may depend on a
# successful write, because a failed write is the thing being checked for.
STAGED_GITLINKS=""

SKIPPED_CHECKS=()
SUPPRESSED=0

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
MODE="tree"
EXPLICIT=()
for arg in "$@"; do
  case "$arg" in
    --staged) MODE="staged" ;;
    --tree)   MODE="tree" ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "pii_scan: unknown option $arg" >&2; exit 2 ;;
    *)  MODE="explicit"; EXPLICIT+=("$arg") ;;
  esac
done

# The staging directory is created HERE, at the top level, rather than inside
# build_filelist. That function runs inside a pipeline, so it runs in a
# subshell, and an exit from a subshell would leave the caller with an empty
# file list, which this scanner reports as "nothing to scan" and exits 0 on.
# A staging directory that could not be created must stop the run, not empty it.
if [ "$MODE" = "staged" ]; then
  mkdir -p "$STAGED_ROOT" || {
    echo "pii_scan: cannot create the staged snapshot directory $STAGED_ROOT" >&2
    exit 2
  }
  STAGED_GITLINKS="$(git -C "$REPO_ROOT" ls-files --stage 2>/dev/null \
    | awk -F'\t' '{split($1,a," "); if (a[1]=="160000") print $2}')"
fi

# True when $1 is one of the staged submodule paths. A pure shell membership
# test, so it costs no process and needs no file.
is_gitlink() {
  case $'\n'"$STAGED_GITLINKS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# The paths this scanner deliberately never reads, because they are the
# scanner's own configuration and two of them hold, by design, exactly the
# content it exists to detect. Named once so the file list and the staged
# integrity check below cannot disagree about what is expected to be there.
is_own_config() {
  case "$1" in
    tools/pii_scan.sh|tools/pii_allowlist.txt|tools/pii_context.txt|tools/pii_names.txt) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# File list
# ---------------------------------------------------------------------------
build_filelist() {
  case "$MODE" in
    staged)
      # The question this mode answers is what the COMMIT will carry, and that
      # is the index, not the working tree. This branch used to take its names
      # from the index and then read its bytes from disk, which are two
      # different things whenever they disagree:
      #   - a secret staged and then edited out of the file passed the gate
      #     while the committed blob still carried it
      #   - a partially staged file was judged on the unstaged half
      #   - a staged file deleted from the tree disappeared from the scan
      # None of those is a contrived interleave. All three are ordinary git.
      #
      # So every staged blob is written out under STAGED_ROOT and scanned
      # there, text and media alike. Paths keep their repository-relative
      # shape below STAGED_ROOT, so an allowlist entry still matches on its
      # path substring and an inline pii-allow marker is read from the bytes
      # being committed rather than from whatever the tree happens to hold.
      # record() maps the prefix back so no temporary path is ever printed.
      git -C "$REPO_ROOT" -c core.quotePath=false \
          diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            # A path that would escape the snapshot root. Only a genuine parent
            # component counts. An earlier cut matched any name beginning with
            # a pair of dots, which silently dropped ordinary files like ..env
            # and ..secrets/token out of the scan, and a dropped file is an
            # unscanned file. git never emits a traversing path, and if one
            # ever appeared the integrity check below the pipeline would see
            # the missing snapshot and stop the run.
            case "$rel" in /*|..|../*|*/../*|*/..) continue ;; esac
            is_gitlink "$rel" && continue
            # Nothing in this loop decides whether the run may pass. It runs in
            # a subshell, so it cannot stop the script, and the failure most
            # worth catching (a write that did not happen) is the same failure
            # that would stop it recording anything. The integrity check below
            # the pipeline is what rules, and it reads the snapshot itself.
            mkdir -p "$STAGED_ROOT/$(dirname "$rel")" 2>/dev/null || continue
            git -C "$REPO_ROOT" show ":$rel" > "$STAGED_ROOT/$rel" 2>/dev/null \
              && printf '%s\n' "$STAGED_ROOT/$rel"
          done
      ;;
    explicit)
      printf '%s\n' "${EXPLICIT[@]}"
      ;;
    tree)
      find "$REPO_ROOT" \
        -type d \( -name .git -o -name '.venv*' -o -name node_modules \
                   -o -name __pycache__ -o -name renders -o -name state \) -prune -o \
        -type f -print
      ;;
  esac
}

# record is defined before its first use below. It used to sit two hundred lines later,
# so the wall check under it logged a command-not-found instead of a BLOCKER.
#
# In staged mode the bytes under examination sit in a temporary snapshot nobody
# can open after the run. The finding is about the repository path, so the
# prefix is mapped back here, in the single place every finding passes through.
#
# The append is checked. A probe taken earlier says the filesystem was writable
# THEN, which is not the same as saying this write landed, and a finding that
# could not be written is a finding that will not be reported: the totals would
# come out zero and the run would print PASS. This is the one write in the file
# where losing bytes silently converts a failure into a success.
record() {
  local p="$1"
  case "$p" in "$STAGED_ROOT"/*) p="$REPO_ROOT/${p#"$STAGED_ROOT"/}" ;; esac
  if ! printf '%s:%s:%s:%s:%s\n' "$p" "$2" "$3" "$4" "$5" >> "$HITS"; then
    echo "pii_scan: a finding could not be written to the findings file." >&2
    echo "A finding that cannot be recorded cannot be reported, so this run" >&2
    echo "cannot pass. Check for a full disk on ${TMPDIR:-/tmp}." >&2
    exit 2
  fi
}

# The two local-only inputs hold real third-party names and project words BY
# DESIGN, so their single wall is .gitignore. Nothing asserted that wall held
# until the judgement layer flagged both files in a tree review; a one-line
# gitignore regression (or a git add -f) would have published the roster. So
# the wall itself is now a check: if either file exists AND is not ignored,
# that is a BLOCKER before any content scanning happens.
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  for _lo in "$CONTEXT_FILE" "$NAMES_FILE"; do
    [ -f "$_lo" ] || continue
    if ! git -C "$REPO_ROOT" check-ignore -q "$_lo" 2>/dev/null; then
      record "$_lo" 0 "CLASS4-THIRD-PARTY" "BLOCKER" "local-only-scanner-input-not-gitignored"
    fi
  done
fi

build_filelist \
  | grep -v -e '/\.git/' \
  | grep -v -e '/tools/pii_scan\.sh$' -e '/tools/pii_allowlist\.txt$' \
            -e '/tools/pii_context\.txt$' -e '/tools/pii_names\.txt$' \
  | sort -u > "$FILELIST"

# STAGED INTEGRITY. An unscanned file must never be counted as a clean one, so
# the snapshot is verified POSITIVELY: every staged path is either a submodule,
# which carries no blob, or must exist in the snapshot at exactly the byte
# count the index records for it. Size equality is what catches a truncated
# write, which is what a full disk produces and what a bare existence test
# would wave through.
#
# The check deliberately depends on no marker file and no earlier write of its
# own. A first attempt at this recorded failures into a file on the same
# temporary filesystem, which is fail-open by construction: the disk that
# stopped the blob from being written also stops the failure from being
# recorded, leaving an empty marker, an empty file list, and the exit-0
# "nothing to scan" path. This runs at the top level, reads only git and the
# snapshot, and can stop the script itself.
if [ "$MODE" = "staged" ]; then
  staged_bad=""
  staged_want=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in /*|..|../*|*/../*|*/..) staged_bad="$staged_bad
  $rel (path escapes the snapshot root)"; continue ;; esac
    is_gitlink "$rel" && continue
    is_own_config "$rel" && continue
    staged_want=$((staged_want + 1))
    want="$(git -C "$REPO_ROOT" cat-file -s ":$rel" 2>/dev/null)"
    have="$(wc -c < "$STAGED_ROOT/$rel" 2>/dev/null | tr -d ' ')"
    if [ -z "$want" ] || [ "$want" != "${have:-missing}" ]; then
      staged_bad="$staged_bad
  $rel (index says ${want:-unreadable} bytes, snapshot has ${have:-nothing})"
    fi
  done < <(git -C "$REPO_ROOT" -c core.quotePath=false \
             diff --cached --name-only --diff-filter=ACMR 2>/dev/null)

  if [ -n "$staged_bad" ]; then
    echo "pii_scan: the staged snapshot is incomplete:$staged_bad" >&2
    echo "pii_scan: a file that could not be read has not been scanned, so this" >&2
    echo "run cannot report a pass. Free disk space or repair the index, then" >&2
    echo "run it again." >&2
    exit 2
  fi

  # The list itself can be lost after the snapshot succeeds, for the same
  # reason, and an empty list is the one input this scanner answers with a
  # cheerful exit 0. So the count is asserted rather than assumed.
  staged_have="$(wc -l < "$FILELIST" | tr -d ' ')"
  if [ "$staged_have" -lt "$staged_want" ]; then
    echo "pii_scan: $staged_want staged file(s) were snapshotted but only" >&2
    echo "$staged_have reached the scan list. Refusing to report on a list that" >&2
    echo "lost its contents." >&2
    exit 2
  fi
fi

if grep -q ':' "$FILELIST"; then
  echo "pii_scan: a path contains a colon, which breaks the path:line output contract" >&2
  exit 2
fi

FILE_COUNT=$(wc -l < "$FILELIST" | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "pii_scan: nothing to scan (mode=$MODE)"
  exit 0
fi

: > "$TEXTLIST"; : > "$MEDIALIST"
UNCLASSIFIED=0
while IFS= read -r f; do
  # A zero-byte file is neither text nor media: no content, no embedded
  # metadata. Without this test an empty file fails the text probe and lands
  # in the media list, where a machine with no metadata reader fails closed
  # on it. That exact chain fired in CI when the workflow's own (empty at
  # list-build time) output redirect landed inside the tree, and the scanner
  # reported its own log file as an unverifiable HIGH finding.
  [ -s "$f" ] || { UNCLASSIFIED=$((UNCLASSIFIED + 1)); continue; }
  [ -f "$f" ] || { UNCLASSIFIED=$((UNCLASSIFIED + 1)); continue; }
  case "$f" in
    *.png|*.jpg|*.jpeg|*.webp|*.gif|*.heic|*.tif|*.tiff|*.mp4|*.mov|*.m4v|*.webm\
    |*.wav|*.mp3|*.m4a|*.aac|*.flac|*.pdf)
      printf '%s\n' "$f" >> "$MEDIALIST"; continue ;;
  esac
  if grep -Iq . "$f" 2>/dev/null; then
    printf '%s\n' "$f" >> "$TEXTLIST"
  else
    printf '%s\n' "$f" >> "$MEDIALIST"
  fi
done < "$FILELIST"

# CLASSIFICATION INTEGRITY. Every file on the list either reached the text list,
# reached the media list, or was deliberately skipped. Those three numbers must
# add up to the list, and if they do not then a write failed and a file passed
# through the scanner without being examined by either pass. Nothing else in
# this script would have noticed: the run would print a smaller media count and
# a cheerful RESULT: PASS.
#
# This is the shape of the whole file. Scratch writes here are not individually
# checked, and rewriting that error model is a bigger change than this one, so
# the invariant is asserted at the point where a lost write becomes a lost
# scan, which is the only place it actually matters.
_n_text=$(wc -l < "$TEXTLIST" | tr -d ' ')
_n_media=$(wc -l < "$MEDIALIST" | tr -d ' ')
if [ "$((_n_text + _n_media + UNCLASSIFIED))" -ne "$FILE_COUNT" ]; then
  echo "pii_scan: $FILE_COUNT file(s) to classify, but $_n_text reached the text" >&2
  echo "list, $_n_media reached the media list and $UNCLASSIFIED were skipped." >&2
  echo "A file that reached neither list was never scanned, so this run cannot" >&2
  echo "report a pass. Check for a full disk on ${TMPDIR:-/tmp}." >&2
  exit 2
fi

# And the scratch filesystem is probed once more before any finding is
# recorded, because a disk that filled while the snapshot was being written
# would silently drop every append to the findings file after it.
if ! printf 'probe\n' > "$TMPDIR_RUN/write.probe" 2>/dev/null \
   || [ ! -s "$TMPDIR_RUN/write.probe" ]; then
  echo "pii_scan: ${TMPDIR:-/tmp} is no longer writable, so a finding recorded" >&2
  echo "from here on would be lost. Refusing to report on a run that cannot" >&2
  echo "keep its own notes." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Rule table. Fields are TAB separated so a regex may contain a pipe.
#   SEVERITY <TAB> CLASS <TAB> LABEL <TAB> EXTENDED-REGEX
# Only BLOCKER and HIGH fail the run. MEDIUM and LOW print for human judgement.
# Every regex here is a generic shape. No employer, product, person, or place
# name appears, by design (see the header).
#
# Note on opaque-20-char-identifier: a bare twenty character alphanumeric token
# is the shape of a cloned-voice identifier, and this pipeline is built on
# cloned-voice and generated-avatar assets, so it is rated HIGH rather than
# MEDIUM even though it will occasionally fire on a hash or a base64 fragment.
# A false positive costs one suppression line. A missed voice id is permanent.
# ---------------------------------------------------------------------------
read -r -d '' RULES <<'RULES_EOF'
BLOCKER	CLASS1-CREDENTIALS	chat-workspace-token	xox[abceprs]-[A-Za-z0-9-]{8,}
BLOCKER	CLASS1-CREDENTIALS	cloud-access-key-id	AKIA[0-9A-Z]{16}
BLOCKER	CLASS1-CREDENTIALS	forge-personal-access-token	gh[pousr]_[0-9A-Za-z]{20,}
BLOCKER	CLASS1-CREDENTIALS	anthropic-api-key	sk-ant-[0-9A-Za-z_-]{20,}
BLOCKER	CLASS1-CREDENTIALS	model-api-key-scoped	sk-(proj|svcacct|admin|live|test)-[A-Za-z0-9_-]{16,}
BLOCKER	CLASS1-CREDENTIALS	model-api-key-legacy	(^|[^A-Za-z0-9-])sk-[A-Za-z0-9]{32,}
BLOCKER	CLASS1-CREDENTIALS	cloud-platform-api-key	AIza[0-9A-Za-z_-]{30,}
BLOCKER	CLASS1-CREDENTIALS	model-hub-token	\bhf_[A-Za-z0-9]{28,}
BLOCKER	CLASS1-CREDENTIALS	datacenter-forge-token	BBDC-[A-Za-z0-9]{8,}
BLOCKER	CLASS1-CREDENTIALS	ci-personal-access-token	pat\.[A-Za-z0-9_-]{20,24}\.[a-f0-9]{20,}\.[A-Za-z0-9]{16,}
BLOCKER	CLASS1-CREDENTIALS	pem-private-key-block	-----BEGIN ([A-Z]+ )?PRIVATE KEY-----
BLOCKER	CLASS1-CREDENTIALS	json-web-token	\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}
BLOCKER	CLASS1-CREDENTIALS	idp-subject-identifier	auth0\|[a-f0-9]{20,}
BLOCKER	CLASS1-CREDENTIALS	keychain-retrieval-command	find-generic-password
BLOCKER	CLASS1-CREDENTIALS	keychain-service-name	keychain[_-]?service
BLOCKER	CLASS1-CREDENTIALS	connection-string-password	[a-z][a-z0-9+.-]*://[A-Za-z0-9._%-]+:[^@/[:space:]]{4,}@
BLOCKER	CLASS1-CREDENTIALS	inline-authorization-header	[Aa]uthorization[[:space:]]*:[[:space:]]*(Bearer|Basic|Token)[[:space:]]+[A-Za-z0-9._~+/=-]{16,}
HIGH	CLASS1-CREDENTIALS	vendor-api-key-header	xi-api-key|x-api-key[[:space:]]*[:=][[:space:]]*["'][A-Za-z0-9]
HIGH	CLASS1-CREDENTIALS	absolute-secret-file-path	(source|^\.|[[:space:]]\.)[[:space:]]+[~$/][^[:space:]]*\.env\b
HIGH	CLASS1-CREDENTIALS	permission-bypass-flag	bypassPermissions|dangerously-skip-permissions|--no-verify
MEDIUM	CLASS1-CREDENTIALS	named-credential-env-var	[A-Z][A-Z0-9_]{2,}_(TOKEN|API_KEY|APIKEY|SECRET|PASSWORD|CREDENTIAL)[[:space:]]*=
BLOCKER	CLASS2-VENDOR-ASSET-ID	hex32-asset-identifier	\b[0-9a-f]{32}\b
BLOCKER	CLASS2-VENDOR-ASSET-ID	voice-identifier-assignment	(voice[_-]?id|VOICE_ID|\bVID)["']?[[:space:]]*[:=][[:space:]]*["']?[A-Za-z0-9]{16,32}\b
BLOCKER	CLASS2-VENDOR-ASSET-ID	asset-identifier-assignment	(avatar([_-]?group)?[_-]?id|look[_-]?id|video[_-]?id|asset[_-]?id|group[_-]?id|clone[_-]?id)["']?[[:space:]]*[:=][[:space:]]*["']?[A-Za-z0-9_-]{12,}
HIGH	CLASS2-VENDOR-ASSET-ID	uuid	\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b
HIGH	CLASS2-VENDOR-ASSET-ID	truncated-hex-identifier	\b[0-9a-f]{8,}\.\.\.
HIGH	CLASS2-VENDOR-ASSET-ID	vendor-job-identifier	\b(gen|task|job|run)_[0-9a-zA-Z]{16,}
HIGH	CLASS2-VENDOR-ASSET-ID	chat-file-identifier	\bF0[A-Z0-9]{8,}\b
HIGH	CLASS2-VENDOR-ASSET-ID	opaque-20-char-identifier	\b[A-Za-z0-9]{20}\b
BLOCKER	CLASS3-FIRST-PARTY	home-directory-username-path	/Users/[A-Za-z0-9][A-Za-z0-9._-]+|/home/[a-z][a-z0-9._-]+
BLOCKER	CLASS3-FIRST-PARTY	email-address	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
BLOCKER	CLASS3-FIRST-PARTY	phone-e164	\+[1-9][0-9]{9,14}\b
BLOCKER	CLASS3-FIRST-PARTY	phone-national	\b[0-9]{3}[-.][0-9]{3}[-.][0-9]{4}\b|\([0-9]{3}\)[[:space:]]?[0-9]{3}-[0-9]{4}
BLOCKER	CLASS3-FIRST-PARTY	national-id-number	\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b
BLOCKER	CLASS3-FIRST-PARTY	payment-card-number	\b[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}\b|\b[0-9]{15,16}\b
BLOCKER	CLASS3-FIRST-PARTY	private-lan-address	\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b
BLOCKER	CLASS3-FIRST-PARTY	local-network-hostname	\b[a-z0-9][a-z0-9-]*\.(local|lan|home|internal)\b
BLOCKER	CLASS3-FIRST-PARTY	vpn-tunnel-hostname	\.ts\.net\b|\.tailscale\b|\.zerotier\b
BLOCKER	CLASS3-FIRST-PARTY	messaging-account-identifier	[0-9]{10,}@(g\.us|s\.whatsapp\.net|c\.us)
BLOCKER	CLASS3-FIRST-PARTY	chat-workspace-object-id	\b[UDCBTGWE]0[A-Z0-9]{8,}\b
BLOCKER	CLASS3-FIRST-PARTY	ssh-user-at-host	\b[a-z_][a-z0-9_.-]*@[a-z0-9-]+\.(local|lan|home|internal)\b
HIGH	CLASS3-FIRST-PARTY	hardware-address	\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b
HIGH	CLASS3-FIRST-PARTY	private-tooling-path	~/\.claude/|\$HOME/\.claude/|/\.claude/(skills|memory|projects)/
HIGH	CLASS3-FIRST-PARTY	personal-mail-or-calendar-ingest	Calendar\.app|Mail\.app|iCloud|Photos library|osascript[^\n]*(Calendar|Mail|Photos)
HIGH	CLASS3-FIRST-PARTY	scratchpad-session-path	/private/tmp/[A-Za-z0-9._-]+/-Users-
MEDIUM	CLASS3-FIRST-PARTY	ipv6-address	\b([0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}\b
MEDIUM	CLASS3-FIRST-PARTY	dotted-quad-address	\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
MEDIUM	CLASS3-FIRST-PARTY	reverse-dns-bundle-identifier	\bcom\.[a-z][a-z0-9]*\.[a-z][a-z0-9-]+\b
BLOCKER	CLASS5-WORKPLACE	issue-tracker-key	\b[A-Z]{2,6}-[0-9]{2,6}\b
BLOCKER	CLASS5-WORKPLACE	tenant-issue-tracker-host	[A-Za-z0-9-]+\.atlassian\.net
BLOCKER	CLASS5-WORKPLACE	tenant-chat-archive-link	[A-Za-z0-9-]+\.slack\.com/archives
HIGH	CLASS5-WORKPLACE	tenant-monitoring-host	[A-Za-z0-9-]+\.(airbrake|datadoghq|pagerduty|postman)\.(io|com|co)
HIGH	CLASS5-WORKPLACE	sprint-reference	\bSprint[[:space:]]+[0-9]+\b
# internal-cluster-reference: the namespace arm requires a digit or hyphen in
# the following token. It used to accept any 6+ letter word, so ordinary prose
# ("the environment-variable namespace matched") in a commit message failed CI
# as a workplace cluster reference. An identifier shape, not an English word,
# is what makes it a cluster ref.
HIGH	CLASS5-WORKPLACE	internal-cluster-reference	\bEKS\b|\bnamespace[[:space:]]+([a-z0-9-]*[0-9][a-z0-9-]*|[a-z0-9]+(-[a-z0-9]+)+)\b|staging[0-9]{1,3}\b
MEDIUM	CLASS5-WORKPLACE	forge-repository-link	(bitbucket\.org|gitlab\.com|dev\.azure\.com)/[A-Za-z0-9._-]+/
HIGH	CLASS6-BEHAVIORAL	wall-clock-time	\b([01][0-9]|2[0-3]):[0-5][0-9]\b
HIGH	CLASS6-BEHAVIORAL	timestamped-event	20[0-9]{2}-[01][0-9]-[0-3][0-9][ T]([01][0-9]|2[0-3]):[0-5][0-9]
HIGH	CLASS6-BEHAVIORAL	presence-or-routine-prose	while (you|he|she|they) (are|is|were|was) asleep|every (morning|night|evening)|overnight (run|session)|wake time|goes to sleep|just-past-midnight|before (dawn|sunrise)
HIGH	CLASS6-BEHAVIORAL	private-conversation-quote	(said|says|asked|wrote|told me)[[:space:]]*[:,][[:space:]]*["']
MEDIUM	CLASS6-BEHAVIORAL	cron-expression	(^|["'[:space:]])[0-9*/,-]{1,20}[[:space:]]+[0-9*/,-]{1,20}[[:space:]]+[0-9*/,-]{1,20}[[:space:]]+[0-9*/,-]{1,20}[[:space:]]+[0-9*/,-]{1,20}([[:space:]]|["']|$)
MEDIUM	CLASS6-BEHAVIORAL	scheduler-job-definition	StartCalendarInterval|StartInterval|RunAtLoad|launchd|systemd timer
MEDIUM	CLASS6-BEHAVIORAL	account-financial-state	credits? remaining|credit balance|billing cycle|renewal date|subscription tier|Plan:[[:space:]]*(pro|team|enterprise)
MEDIUM	CLASS6-BEHAVIORAL	private-corpus-ingest	session transcripts?|/projects/[^[:space:]]*\.jsonl|history/logs\.md|self-model|job.search
MEDIUM	CLASS6-BEHAVIORAL	timezone-disclosure	\b(America|Europe|Asia|Australia|Africa|Pacific)/[A-Z][A-Za-z_]+\b
RULES_EOF

# ---------------------------------------------------------------------------
# Project-specific fragments, loaded from a local gitignored file.
# Format: one line per rule,  SEVERITY <TAB> CLASS <TAB> LABEL <TAB> REGEX
#         optional 5th field:  <TAB> GREP FLAGS   (e.g. -i). Omit for exact case.
# Lines beginning with # are comments. Blank lines are skipped.
# ---------------------------------------------------------------------------
EXTRA_RULES=""
if [ -r "$CONTEXT_FILE" ]; then
  EXTRA_RULES="$(grep -v '^[[:space:]]*#' "$CONTEXT_FILE" | grep -v '^[[:space:]]*$' || true)"
fi
if [ -z "$EXTRA_RULES" ]; then
  SKIPPED_CHECKS+=("class 5 and class 6 project-specific words (no $CONTEXT_FILE)")
fi

# ---------------------------------------------------------------------------
# Class 4 person names. Never written into this repository.
# ---------------------------------------------------------------------------
ROSTER_PATTERN=""
if [ -r "$ROSTER_LIB" ]; then
  # shellcheck disable=SC1090
  . "$ROSTER_LIB" 2>/dev/null || true
  if type _pii_roster_name_pattern >/dev/null 2>&1; then
    ROSTER_PATTERN="$(_pii_roster_name_pattern 2>/dev/null || true)"
  fi
fi
if [ -r "$NAMES_FILE" ]; then
  while IFS= read -r n; do
    case "$n" in ''|'#'*) continue ;; esac
    # Letters, spaces, hyphen and apostrophe. A real roster holds O'Connor and
    # Anne-Marie, and letters-and-spaces dropped both of them without a word,
    # leaving an explicitly configured third party unguarded while the summary
    # still said the class was armed. Neither character is special in an
    # extended regex, so widening costs nothing. Everything else stays refused
    # on purpose: these names are joined with a pipe and handed to grep, and
    # that gate is what keeps a metacharacter out of the emitted pattern.
    case "$n" in *[!A-Za-z\ \'-]*) continue ;; esac
    if [ -z "$ROSTER_PATTERN" ]; then ROSTER_PATTERN="$n"; else ROSTER_PATTERN="$ROSTER_PATTERN|$n"; fi
  done < "$NAMES_FILE"
fi
[ -n "$ROSTER_PATTERN" ] || SKIPPED_CHECKS+=("class 4 third-party names (no roster and no $NAMES_FILE)")

# ---------------------------------------------------------------------------
# Owner identity, derived at runtime so no personal token is hardcoded here.
# ---------------------------------------------------------------------------
OWNER_PATTERN=""
add_owner() {
  local t="$1"
  [ -n "$t" ] || return 0
  case "$t" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#t}" -ge 3 ] || return 0
  # Platform-default usernames identify no one, so they must not become owner
  # tokens. On a GitHub runner `id -un` is literally "runner", and because the
  # owner rule matches case-insensitively (a real name is not case-stable in
  # prose), the derived token matched RUNNER_TEMP in the workflow file itself:
  # the scanner flagged the platform's own vocabulary as the operator's
  # identity. An owner check exists to catch the OPERATOR's name; a username
  # shared by every tenant of the platform asserts nothing about them. When
  # this filter leaves the pattern empty, the check is SKIPPED and says so,
  # which is the honest state: CI genuinely does not know the operator's name.
  case "$(printf '%s' "$t" | tr 'A-Z' 'a-z')" in
    runner|root|admin|user|ubuntu|debian|ec2-user|jenkins|ci|build|builder|github|actions|worker|agent) return 0 ;;
  esac
  t="$(printf '%s' "$t" | sed 's/[.]/\\./g')"
  if [ -z "$OWNER_PATTERN" ]; then OWNER_PATTERN="$t"; else OWNER_PATTERN="$OWNER_PATTERN|$t"; fi
}
add_owner "$(id -un 2>/dev/null)"
for tok in $(git -C "$REPO_ROOT" config user.name 2>/dev/null); do add_owner "$tok"; done
gitmail="$(git -C "$REPO_ROOT" config user.email 2>/dev/null)"
add_owner "${gitmail%%@*}"
[ -n "$OWNER_PATTERN" ] || SKIPPED_CHECKS+=("class 3 owner-identity tokens (no login and no git identity)")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_allowlisted() {
  local path="$1" lineno="$2" label="$3" content pat lbl
  if [ "$lineno" != "0" ]; then
    content="$(sed -n "${lineno}p" "$path" 2>/dev/null)"
    case "$content" in *pii-allow*) return 0 ;; esac
  fi
  [ -r "$ALLOWLIST" ] || return 1
  while IFS='|' read -r pat lbl; do
    case "$pat" in ''|'#'*) continue ;; esac
    [ -n "${lbl:-}" ] || continue
    case "$path" in *"$pat"*) [ "$lbl" = "$label" ] && return 0 ;; esac
  done < "$ALLOWLIST"
  return 1
}


run_rule() {
  # $1 severity  $2 class  $3 label  $4 regex  $5 file list  $6 extra grep flags
  # $6 exists because a name is not case-stable in prose. A comment SHOUTING
  # a name in caps carries the same identity token as the ordinary spelling,
  # and a case-sensitive pattern passed exactly that, silently, in this repo.
  # Only rules whose pattern is genuinely case-insensitive should pass -i;
  # hex, base64 and key formats must not, or they gain false positives.
  local sev="$1" cls="$2" label="$3" re="$4" list="$5" gflags="${6:-}" path lineno
  [ -s "$list" ] || return 0
  # Only fields 1 and 2 of the grep output are read, so the matched text never
  # leaves this function. -a keeps grep working on files with odd bytes.
  while IFS=: read -r path lineno _rest; do
    [ -n "${lineno:-}" ] || continue
    case "$lineno" in ''|*[!0-9]*) continue ;; esac
    if is_allowlisted "$path" "$lineno" "$label"; then
      SUPPRESSED=$((SUPPRESSED + 1)); continue
    fi
    record "$path" "$lineno" "$cls" "$sev" "$label"
  done < <(tr '\n' '\0' < "$list" | xargs -0 grep -a -n -H -E $gflags -e "$re" 2>/dev/null)
}

apply_rule_table() {
  # Field 5 is optional grep flags. It exists because run_rule has always
  # accepted a flags argument and this loop never passed one, so every table
  # rule ran case-sensitive and a name spelled one way let the other spellings
  # through without a word of complaint. Absent field 5 keeps the old
  # behaviour, which the identifier rules depend on.
  local table="$1" list="$2" sev cls label re flags
  while IFS=$'\t' read -r sev cls label re flags; do
    [ -n "${re:-}" ] || continue
    run_rule "$sev" "$cls" "$label" "$re" "$list" "${flags:-}"
  done <<< "$table"
}

# ---------------------------------------------------------------------------
# Pass 1, content rules
# ---------------------------------------------------------------------------
apply_rule_table "$RULES" "$TEXTLIST"
[ -n "$EXTRA_RULES" ] && apply_rule_table "$EXTRA_RULES" "$TEXTLIST"
[ -n "$ROSTER_PATTERN" ] && run_rule "BLOCKER" "CLASS4-THIRD-PARTY" "known-person-name" "$ROSTER_PATTERN" "$TEXTLIST"
[ -n "$OWNER_PATTERN" ] && run_rule "HIGH" "CLASS3-FIRST-PARTY" "owner-identity-token" "$OWNER_PATTERN" "$TEXTLIST" "-i"

# ---------------------------------------------------------------------------
# Pass 2, filenames. An identifier in the name of a file survives every
# content-level scrub and still escapes through directory listings.
# ---------------------------------------------------------------------------
while IFS= read -r f; do
  base="$(basename "$f")"
  printf '%s' "$base" | grep -qE '[0-9a-f]{32}' \
    && record "$f" 0 "CLASS2-VENDOR-ASSET-ID" "BLOCKER" "asset-id-in-filename"
  printf '%s' "$base" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    && record "$f" 0 "CLASS2-VENDOR-ASSET-ID" "HIGH" "uuid-in-filename"
  [ -n "$OWNER_PATTERN" ] && printf '%s' "$base" | grep -qE "$OWNER_PATTERN" \
    && record "$f" 0 "CLASS3-FIRST-PARTY" "HIGH" "owner-identity-in-filename"
  case "$base" in
    *backup*|*.bak|*.keep|*~|*.orig)
      record "$f" 0 "CLASS3-FIRST-PARTY" "HIGH" "stale-backup-file-in-tree" ;;
  esac
  case "$base" in
    .env|.env.*|*.pem|*.p12|*.pfx|*.key|id_rsa*|id_ed25519*|*.plist)
      record "$f" 0 "CLASS1-CREDENTIALS" "BLOCKER" "secret-bearing-filename" ;;
  esac
done < "$FILELIST"

# ---------------------------------------------------------------------------
# Pass 3, class 7 media metadata. Regex cannot see EXIF, so this shells out.
# If no metadata reader is installed and media is present, that is reported as
# HIGH rather than passed over. Unverified is not the same as clean.
# ---------------------------------------------------------------------------
if [ -s "$MEDIALIST" ]; then
  META_TOOL=""
  if   command -v exiftool >/dev/null 2>&1; then META_TOOL="exiftool"
  elif command -v ffprobe  >/dev/null 2>&1; then META_TOOL="ffprobe"; fi

  if [ -z "$META_TOOL" ]; then
    while IFS= read -r f; do
      record "$f" 0 "CLASS7-MEDIA-METADATA" "HIGH" "metadata-unverifiable-no-reader-installed"
    done < "$MEDIALIST"
  else
    while IFS= read -r f; do
      if [ "$META_TOOL" = "exiftool" ]; then
        meta="$(exiftool -s -G "$f" 2>/dev/null)"
      else
        meta="$(ffprobe -v quiet -show_format -show_streams "$f" 2>/dev/null)"
      fi
      [ -n "$meta" ] || continue
      printf '%s' "$meta" | grep -qiE 'gps|latitude|longitude' \
        && record "$f" 0 "CLASS7-MEDIA-METADATA" "BLOCKER" "embedded-gps-coordinates"
      printf '%s' "$meta" | grep -qiE 'serial' \
        && record "$f" 0 "CLASS7-MEDIA-METADATA" "BLOCKER" "embedded-device-serial"
      printf '%s' "$meta" | grep -qiE 'artist|by-?line|creator|copyright|owner|author' \
        && record "$f" 0 "CLASS7-MEDIA-METADATA" "HIGH" "embedded-author-or-copyright"
      printf '%s' "$meta" | grep -qiE 'make|camera|lens|software|host computer|encoder' \
        && record "$f" 0 "CLASS7-MEDIA-METADATA" "HIGH" "embedded-device-or-software"
      # A timestamp field only leaks if it carries a VALUE. ffmpeg's -fflags +bitexact
      # zeroes these to 0000:00:00 00:00:00 rather than removing the field, because the
      # container requires it structurally. Flagging the field name alone made a
      # correctly-scrubbed file indistinguishable from a leaky one, which trains a
      # reviewer to wave the finding through. So: match the field, then require a
      # non-zero value before recording. usercomment and xmp are free text and stay
      # flagged on presence, since any content there is authored rather than structural.
      if printf '%s' "$meta" | grep -qiE 'usercomment|xmp'; then
        record "$f" 0 "CLASS7-MEDIA-METADATA" "MEDIUM" "embedded-timestamp-or-xmp"
      elif printf '%s' "$meta" | grep -iE 'date/?time|createdate|creation_time' \
           | grep -qvE '0000:00:00|1970:01:01|: *$'; then
        record "$f" 0 "CLASS7-MEDIA-METADATA" "MEDIUM" "embedded-timestamp-or-xmp"
      fi
    done < "$MEDIALIST"
  fi
fi

# ---------------------------------------------------------------------------
# Pass 4, git history. A working-tree scan misses commit messages and the author
# identity git stamps into every commit object, and it misses blobs that were
# deleted from the tree but remain reachable. A repo with no commits is the
# cheapest possible moment to fix this.
# ---------------------------------------------------------------------------
if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  ident="$(git -C "$REPO_ROOT" log --format='%an|%ae|%cn|%ce' 2>/dev/null | sort -u)"
  # These two go through is_allowlisted like every other rule. They used to call
  # record directly, which meant a finding on git metadata could not be
  # suppressed by any mechanism the tool documents, so the gate stayed red
  # forever on a repo whose author email is already public. An unsuppressible
  # finding is not a strict gate, it is a broken one: it trains the operator to
  # bypass the whole hook rather than to answer the finding.
  record_identity() {
    if is_allowlisted "$1" 0 "$4"; then SUPPRESSED=$((SUPPRESSED + 1)); return 0; fi
    record "$1" 0 "$2" "$3" "$4"
  }
  printf '%s' "$ident" | grep -qE '@(gmail|icloud|proton|protonmail|outlook|hotmail|yahoo|me)\.' \
    && record_identity "$REPO_ROOT/.git" "CLASS3-FIRST-PARTY" "HIGH" "personal-email-in-commit-identity"
  if [ -n "$ROSTER_PATTERN" ] && printf '%s' "$ident" | grep -qE "$ROSTER_PATTERN"; then
    record_identity "$REPO_ROOT/.git" "CLASS4-THIRD-PARTY" "HIGH" "person-name-in-commit-identity"
  fi

  msgs="$TMPDIR_RUN/commit-messages.txt"
  git -C "$REPO_ROOT" log --format='%H%n%s%n%b' > "$msgs" 2>/dev/null
  scan_history_table() {
    local table="$1" sev cls label re
    while IFS=$'\t' read -r sev cls label re; do
      [ -n "${re:-}" ] || continue
      case "$sev" in BLOCKER|HIGH) ;; *) continue ;; esac
      grep -aqE -e "$re" "$msgs" 2>/dev/null \
        && record "$REPO_ROOT/.git" 0 "$cls" "$sev" "commit-message:$label"
    done <<< "$table"
  }
  scan_history_table "$RULES"
  [ -n "$EXTRA_RULES" ] && scan_history_table "$EXTRA_RULES"

  git -C "$REPO_ROOT" log --diff-filter=D --name-only --format='' 2>/dev/null \
    | grep -qE '\.(env|pem|key|p12|jsonl|plist|hop|log)$' \
    && record "$REPO_ROOT/.git" 0 "CLASS1-CREDENTIALS" "HIGH" "sensitive-file-deleted-but-reachable-in-history"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
sort -u "$HITS" -o "$HITS"

count() { grep -c ":$1:" "$HITS" 2>/dev/null | tr -d ' \n'; }
n_blocker=$(count BLOCKER); n_high=$(count HIGH)
n_medium=$(count MEDIUM);   n_low=$(count LOW)
: "${n_blocker:=0}" "${n_high:=0}" "${n_medium:=0}" "${n_low:=0}"

echo "=== pii_scan: deterministic pass ==="
echo "mode=$MODE  files=$FILE_COUNT  text=$(wc -l < "$TEXTLIST" | tr -d ' ')  media=$(wc -l < "$MEDIALIST" | tr -d ' ')"
echo

for sev in BLOCKER HIGH MEDIUM LOW; do
  if grep -q ":$sev:" "$HITS" 2>/dev/null; then
    echo "--- $sev ---"
    grep ":$sev:" "$HITS"
    echo
  fi
done

if [ "${#SKIPPED_CHECKS[@]}" -gt 0 ]; then
  echo "--- CHECKS SKIPPED (a skipped check is not a passing check) ---"
  for s in "${SKIPPED_CHECKS[@]}"; do echo "  SKIPPED: $s"; done
  echo
fi

echo "totals: blocker=$n_blocker high=$n_high medium=$n_medium low=$n_low suppressed=$SUPPRESSED skipped_checks=${#SKIPPED_CHECKS[@]}"

if [ "$n_blocker" -gt 0 ] || [ "$n_high" -gt 0 ]; then
  echo
  echo "RESULT: FAIL. Publication is irreversible, so this is a hard stop."
  echo "Fix each finding, or add a deliberate suppression that a reviewer can see"
  echo "in the diff (inline pii-allow marker, or tools/pii_allowlist.txt)."
  if [ "${PII_SCAN_SOFT:-0}" = "1" ]; then
    echo "PII_SCAN_SOFT=1 is set, so the exit code is forced to 0. Never set it in the hook."
    exit 0
  fi
  exit 1
fi

echo
echo "RESULT: PASS on deterministic patterns."
echo "That means the known shapes are absent. It does not mean the repo is clean."
echo "Run tools/pii_llm_review.sh for third-party names, routine, and context."
exit 0
