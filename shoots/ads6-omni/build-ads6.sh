#!/usr/bin/env bash
# build-ads6.sh: the Omni Flash leg of the absurd-first four, winner engines, mastering standard.
set -euo pipefail
S=$SHOOT_ROOT; R=$S/takes/ads6-omni; A2=$S/takes/ads2; B=$R/build
mkdir -p "$B"
for AD in orchard lantern harbor slowroad; do
  ln -sfn "$R/$AD-vo" "$B/$AD-vo"
  ln -sfn "$R/$AD-av" "$B/$AD-av"
  for SLOT in a b c; do
    SRC=$R/scenes/$AD-$SLOT/raw.mp4
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
sed -e "s|T=\$S/takes/ads2|T=$B|" "$A2/build-ad.sh" > "$B/build-ad.sh"
python3 - "$B/build-ad.sh" "$R" <<'PYB'
import sys
p, r = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace('TAG="The page that opens the right screen."', 'TAG="One glance, then back to sleep."')
tags = {"orchard": "Roasted the week it lands.", "lantern": "One glance, then back to sleep.", "harbor": "One agent. One street.", "slowroad": "Go slower, see more."}
for ad, tag in tags.items():
    i = s.index(tag)
    j = s.index("BED=", i)
    k = s.index(" ;;", j)
    s = s[:j] + f"BED={r}/beds/{ad}-bed-v1.mp3" + s[k:]
open(p, "w").write(s)
PYB
chmod +x "$B/build-ad.sh"
for AD in orchard lantern harbor slowroad; do (cd "$B" && bash build-ad.sh $AD); done
for AD in orchard lantern harbor slowroad; do
  IN=$B/out-$AD-$AD-av/ad.mp4
  OUT=$RENDERS/ads6omni-$AD-final-v1.mp4
  ffmpeg -v error -y -i "$IN" -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -ar 48000 -ac 2 -c:a aac -b:a 192k -movflags +faststart "$OUT"
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | awk -v ad=$AD '{printf "%s master %.1fs\n", ad, $1}'
done
echo "ads4 build complete"
