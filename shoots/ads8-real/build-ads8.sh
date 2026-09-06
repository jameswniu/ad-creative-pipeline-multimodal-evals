#!/usr/bin/env bash
# build-ads8.sh: five new spec ads (grok/zai/moonshot/claude/claudecode), Omni Flash scenes,
# avatar_iii closers, brands read from boards.json. Optional args limit the build to named spots:
#   bash build-ads8.sh grok zai
set -euo pipefail
# avatar_iii renders align mouth-to-audio by construction; the probe auto-align injected 0.2-0.24s
# of desync on every 2026-08-29 build. Killed HERE so no ads8 build can ever run without the gate.
export CLOSER_AUTOALIGN=0
S=$SHOOT_ROOT; R=$S/takes/ads8-real; A2=$S/takes/ads2; B=$R/build
mkdir -p "$B"
if [ $# -gt 0 ]; then ADS="$*"; else
  ADS=$(python3 -c "import json;print(' '.join(json.load(open('$R/boards.json'))['spots']))")
fi
for AD in $ADS; do
  # bed: lyria2 wav -> mp3 matched to the ads7 reference level (-13.4 LUFS / -0.8 dBTP, chatgpt-bed-v1)
  [ -f "$R/beds/$AD.wav" ] || { echo "MISSING bed $R/beds/$AD.wav"; exit 3; }
  if [ ! -f "$R/beds/$AD-bed-v1.mp3" ] || [ "$R/beds/$AD.wav" -nt "$R/beds/$AD-bed-v1.mp3" ]; then
    ffmpeg -v error -y -i "$R/beds/$AD.wav" \
      -af "loudnorm=I=-13.4:TP=-0.8:LRA=11" -ar 48000 -ac 2 -c:a libmp3lame -q:a 2 "$R/beds/$AD-bed-v1.mp3"
  fi
  ln -sfn "$R/$AD-vo" "$B/$AD-vo"; ln -sfn "$R/$AD-av" "$B/$AD-av"
  for SLOT in a b c; do
    SRC=$R/scenes/$AD-$SLOT/raw.mp4
    [ -f "$SRC" ] || { echo "MISSING $SRC"; exit 3; }
    D=$B/$AD-$SLOT; mkdir -p "$D"
    [ -f "$D/raw.mp4" ] && [ ! "$SRC" -nt "$D/raw.mp4" ] && continue
    HASA=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$SRC" | head -1)
    if [ -n "$HASA" ]; then
      ffmpeg -v error -y -i "$SRC" -vf "scale=1920:1080:flags=lanczos,setsar=1" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 25 -c:a aac -b:a 160k "$D/raw.mp4"
    else
      ffmpeg -v error -y -i "$SRC" -f lavfi -i "anullsrc=r=44100:cl=stereo" -shortest -vf "scale=1920:1080:flags=lanczos,setsar=1" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 25 -c:a aac -b:a 160k "$D/raw.mp4"
    fi
  done
done
# regenerate the builder copy from CANONICAL ads2/build-ad.sh so cap()/CAPSZ typography carries
sed -e "s|T=\$S/takes/ads2|T=$B|" "$A2/build-ad.sh" > "$B/build-ad.sh"
python3 - "$B/build-ad.sh" "$R" <<'PYB'
import json, sys
p, r = sys.argv[1], sys.argv[2]
s = open(p).read()
spots = json.load(open(f"{r}/boards.json"))["spots"]
start = s.index("case $AD in")
end = s.index("esac", start) + 4
block = ["case $AD in"]
for ad, sp in spots.items():
    block.append(f'  {ad})  BRAND="{sp["brand"]}"; TAG="{sp["card"]}"; BED={r}/beds/{ad}-bed-v1.mp3 ;;')
block.append("esac")
open(p, "w").write(s[:start] + "\n".join(block) + s[end:])
print("case block generated for:", ", ".join(spots))
PYB
chmod +x "$B/build-ad.sh"
for AD in $ADS; do (cd "$B" && bash build-ad.sh $AD); done
for AD in $ADS; do
  FINAL="$RENDERS/ads8-$AD-final-${VOUT:-v1}.mp4"
  if [ -f "$FINAL" ] && [ "${VOUT_FORCE:-0}" != "1" ]; then
    echo "REFUSING to overwrite existing final $FINAL (set a new VOUT, or VOUT_FORCE=1)"; exit 4
  fi
  ffmpeg -v error -y -i "$B/out-$AD-$AD-av/ad.mp4" -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -ar 48000 -ac 2 -c:a aac -b:a 192k -movflags +faststart "$FINAL.tmp.mp4"
  mv "$FINAL.tmp.mp4" "$FINAL"
  cp "$B/out-$AD-$AD-av/captions.json" "$RENDERS/ads8-$AD-final-${VOUT:-v1}.captions.json" 2>/dev/null || true
  cp "$B/out-$AD-$AD-av/clean.srt" "$RENDERS/ads8-$AD-final-${VOUT:-v1}.srt" 2>/dev/null || true
done
echo "ads8 build complete: $ADS"
