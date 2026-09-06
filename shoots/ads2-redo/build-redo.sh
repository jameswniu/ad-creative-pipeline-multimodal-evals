#!/usr/bin/env bash
# build-redo.sh <leg>: normalize the leg's 15 scenes to the ads2 geometry, wire the reused vo/av assets and per-brand beds, build 5 spots.
set -euo pipefail
LEG=$1; S=$SHOOT_ROOT; R=$S/takes/ads2-redo; A2=$S/takes/ads2; B=$R/build-$LEG
mkdir -p "$B"
for AD in orchard lantern harbor quiet slowroad; do
  ln -sfn "$A2/$AD-vo" "$B/$AD-vo"
done
ln -sfn "$A2/orchard-av" "$B/orchard-av"; ln -sfn "$A2/lantern-av" "$B/lantern-av"; ln -sfn "$A2/quiet-av" "$B/quiet-av"; ln -sfn "$A2/slowroad-av" "$B/slowroad-av"; ln -sfn "$A2/harbor-maya-av" "$B/harbor-maya-av"
for AD in orchard lantern harbor quiet slowroad; do
  for SLOT in a b c; do
    SRC_SCENE=$AD-$SLOT
    [ "$AD-$SLOT" = "lantern-c" ] && SRC_SCENE=lantern-c2
    SRC=$R/$LEG/$SRC_SCENE/raw.mp4
    [ -f "$SRC" ] || { echo "MISSING $SRC"; exit 3; }
    D=$B/$AD-$SLOT; mkdir -p "$D"
    HASA=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$SRC" | head -1)
    if [ -n "$HASA" ]; then
      ffmpeg -v error -y -i "$SRC" -vf "scale=1920:1080:flags=lanczos,setsar=1" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 25 -c:a aac -b:a 160k "$D/raw.mp4"
    else
      ffmpeg -v error -y -i "$SRC" -f lavfi -i "anullsrc=r=44100:cl=stereo" -shortest -vf "scale=1920:1080:flags=lanczos,setsar=1" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 25 -c:a aac -b:a 160k "$D/raw.mp4"
    fi
  done
done
# patched builder: takes root = build dir, beds from the redo per-brand set
sed -e "s|T=\$S/takes/ads2|T=$B|" "$A2/build-ad.sh" > "$B/build-ad.sh"
python3 - "$B/build-ad.sh" "$R" <<'PYB'
import sys
p, r = sys.argv[1], sys.argv[2]
s = open(p).read()
for ad, old in (("orchard", "bed3"), ("lantern", "bed4"), ("harbor", "bed3"), ("quiet", "bed2"), ("slowroad", "bed3")):
    tag = {"orchard": "Roasted the week it lands.", "lantern": "The page that opens the right screen.", "harbor": "One agent. One street.", "quiet": "Sleep, not stats.", "slowroad": "Go slower, see more."}[ad]
    i = s.index(tag)
    j = s.index("BED=", i)
    k = s.index(" ;;", j)
    s = s[:j] + f"BED={r}/beds/{ad}-bed-v1.mp3" + s[k:]
open(p, "w").write(s)
PYB
chmod +x "$B/build-ad.sh"
for AD in orchard lantern quiet slowroad; do (cd "$B" && bash build-ad.sh $AD); done
(cd "$B" && bash build-ad.sh harbor harbor-maya-av)
for AD in orchard lantern quiet slowroad; do
  cp "$B/out-$AD-$AD-av/ad.mp4" "$RENDERS/ads2redo-$AD-$LEG-final-v1.mp4" 2>/dev/null || cp "$B"/out-$AD-*/ad.mp4 "$RENDERS/ads2redo-$AD-$LEG-final-v1.mp4"
done
cp "$B/out-harbor-harbor-maya-av/ad.mp4" "$RENDERS/ads2redo-harbor-$LEG-final-v1.mp4"
echo "LEG $LEG done"
