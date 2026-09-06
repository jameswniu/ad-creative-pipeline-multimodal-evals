#!/bin/bash
# Block renders that use a voice or avatar which is not the PINNED clone.
# "her" throughout refers to the rendered character; see the README disclosure.
#
# WHY (2026-07-27: "everything must use cloned voice and cloned avatar
# hard config PINNED down" / "can we harden this voice miss!"). On 2026-07-27 a
# 2-minute training render shipped in the WRONG voice. The pins live in prose
# across the pipeline spec and the golden-set spec, and the assistant read a value out of a
# STALE dated BACKUP COPY of the spec instead of the live file, using
# <pinned-voice-id> (two generations old) on the wrong model with the wrong
# settings and a single blind TTS draw. Prose cannot stop that. This can.
#
# Source of truth: the pin file at $IDENTITY_PINS (see README).
#
# What is blocked:
#   1. Any ElevenLabs text-to-speech call whose voice id is not the pinned one.
#      Superseded ids get a louder message naming which generation they are.
#   2. Any HeyGen create_video_* call whose avatar id is neither the pinned base
#      avatar nor a look inside her avatar group (so FRESH looks still pass, a
#      foreign or stock avatar does not).
#
# What is deliberately NOT blocked:
#   - Reading, grepping or editing files that merely CONTAIN old ids (docs,
#     backups, memory, this hook, pins.json itself). Only outbound calls.
#   - The metered voice entrypoint, which reads the pin itself and is sanctioned.
#
# Escape hatch, deliberately manual: touch /tmp/.identity-pin-bypass (120s TTL).
# Use only when I explicitly ask to revert to a previous clone.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

PINS="${IDENTITY_PINS:-$HOME/.config/identity-pins.json}"
VOICE_TAKE="${VOICE_TAKE:-<set VOICE_TAKE to the metered voice entrypoint>}"
REFRESH_PINS="${REFRESH_PINS:-<set REFRESH_PINS to the pin-refresh step>}"
[ -f "$PINS" ] || exit 0

# Never self-block: edits to the hook or the pin file are how these get maintained.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
case "$FILE_PATH" in
  *"block_unpinned_identity.sh"|*"pins.json") exit 0 ;;
esac

# Only OUTBOUND call surfaces are enforced. Authoring a doc, a memory leaf or a
# test fixture that merely mentions a superseded id is legitimate and must not be
# blocked; found while testing this hook on 2026-07-27, when it blocked its own
# test harness. Defense belongs at the call, not at the keyboard.
case "$TOOL_NAME" in
  Bash|mcp__heygen__*|mcp__elevenlabs__*) ;;
  *) exit 0 ;;
esac

# Explicit, short-lived bypass for a sanctioned revert.
if [ -f /tmp/.identity-pin-bypass ]; then
  AGE=$(( $(date +%s) - $(stat -f %m /tmp/.identity-pin-bypass 2>/dev/null || stat -c %Y /tmp/.identity-pin-bypass 2>/dev/null || echo 0) ))
  [ "$AGE" -lt 120 ] && exit 0
fi

PINNED_VOICE=$(jq -r '.voice_id' "$PINS")
PINNED_AVATAR=$(jq -r '.avatar_id' "$PINS")

PAYLOAD=$(echo "$INPUT" | jq -r '.tool_input | tostring' 2>/dev/null)

# ---------- 1. voice ----------
# Match the id out of an ElevenLabs TTS endpoint only. A bare id in prose is fine.
VOICES=$(printf '%s' "$PAYLOAD" | grep -oE 'text-to-speech/[A-Za-z0-9]{16,}' | sed 's#text-to-speech/##' | sort -u)
for V in $VOICES; do
  [ "$V" = "$PINNED_VOICE" ] && continue
  WHICH=$(jq -r --arg v "$V" '.superseded_voice_ids[$v] // ""' "$PINS")
  {
    echo "BLOCKED: this render is using a voice that is not the pinned clone."
    echo ""
    echo "  used:   $V${WHICH:+   ($WHICH)}"
    echo "  pinned: $PINNED_VOICE  ($(jq -r .voice_name "$PINS"))"
    echo ""
    echo "This is the exact miss of 2026-07-27: a stale id read out of a backup"
    echo "file shipped a 2-minute render in the wrong voice."
    echo ""
    echo "Do not hand-roll the TTS call. Use the sanctioned entrypoint:"
    echo "  bash \"$VOICE_TAKE\" <script.txt> <out.mp3> 3"
    echo "It reads the pin itself, draws 3 takes and keeps the median by"
    echo "duration, because a single blind draw lands somewhere on a 6 to 37"
    echo "percent spread and about one in three lands on a tail."
    echo ""
    echo "Pins: $PINS"
  } >&2
  exit 2
done

# ---------- 2. avatar ----------
case "$TOOL_NAME" in
  *heygen*create_video*|*heygen*create_lipsync*)
    A=$(echo "$INPUT" | jq -r '.tool_input.avatarId // .tool_input.avatar_id // ""')
    if [ -n "$A" ] && [ "$A" != "$PINNED_AVATAR" ]; then
      INGROUP=$(jq -r --arg a "$A" '.group_look_ids // [] | index($a) // "" ' "$PINS")
      if [ -z "$INGROUP" ] || [ "$INGROUP" = "null" ]; then
        {
          echo "BLOCKED: this render is using an avatar that is not the pinned clone"
          echo "and is not a look inside her avatar group."
          echo ""
          echo "  used:   $A"
          echo "  pinned: $PINNED_AVATAR  ($(jq -r .avatar_name "$PINS"))"
          echo "  group:  $(jq -r .avatar_group_id "$PINS")"
          echo ""
          echo "Fresh looks ARE allowed, but they must be generated into her group"
          echo "via create_prompt_avatar anchored to that avatarGroupId, and the"
          echo "allowlist refreshed:"
          echo "  bash \"$REFRESH_PINS\""
          echo ""
          echo "Pins: $PINS"
        } >&2
        exit 2
      fi
    fi
    ;;
esac

# ---------- 3. avatar carried by a RAW HTTP CALL (Bash egress) ----------
# Coverage gap, closed 2026-07-28. Check 2 keys on the MCP TOOL NAME, so a curl to
# the vendor REST API from Bash carried an avatar id that nothing ever inspected.
# The voice check above scans ANY payload, so the voice pin was enforced on every
# egress path while the avatar pin was enforced on exactly one. Same pin, same
# verdict, now the same coverage. This matters because the caller is a language
# model: the pipeline spec itself tells it to fall back to curl when an MCP tool is not on
# the allowlist, and the stage scripts grant Bash.
#
# Scope, deliberately narrow: a JSON avatar_id in a payload aimed at the vendor
# API host. Backslashes are stripped first because tool_input arrives re-encoded,
# so the body reads \"avatar_id\" rather than "avatar_id". Keyed on the avatar_id
# FIELD, never on bare 32-char tokens, so a video_id or asset_id cannot false-trip.
if printf '%s' "$PAYLOAD" | grep -q 'api\.heygen\.com'; then
  FLAT=$(printf '%s' "$PAYLOAD" | tr -d '\\')
  for A in $(printf '%s' "$FLAT" \
      | grep -oE '"avatar_?[Ii]d"[[:space:]]*:[[:space:]]*"[A-Za-z0-9]{16,}"' \
      | grep -oE '[A-Za-z0-9]{16,}' | grep -vi '^avatar' | sort -u); do
    [ "$A" = "$PINNED_AVATAR" ] && continue
    INGROUP=$(jq -r --arg a "$A" '.group_look_ids // [] | index($a) // ""' "$PINS")
    [ -n "$INGROUP" ] && [ "$INGROUP" != "null" ] && continue
    {
      echo "BLOCKED: a raw HTTP call to the avatar vendor carries an id that is"
      echo "neither the pinned clone nor a look inside its avatar group."
      echo ""
      echo "  used:   $A"
      echo "  pinned: $PINNED_AVATAR  ($(jq -r .avatar_name "$PINS"))"
      echo "  group:  $(jq -r .avatar_group_id "$PINS")"
      echo ""
      echo "The MCP tool is the sanctioned path; prefer it over hand-rolled curl."
      echo "If a fresh look was just generated, refresh the allowlist first:"
      echo "  bash \"$REFRESH_PINS\""
      echo ""
      echo "Pins: $PINS"
    } >&2
    exit 2
  done
fi

exit 0
