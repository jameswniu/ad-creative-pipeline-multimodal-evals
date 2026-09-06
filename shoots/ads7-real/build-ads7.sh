#!/usr/bin/env bash
# build-ads7.sh: real-product spec ads, Omni Flash default, brands read from boards.json
set -euo pipefail
S=$SHOOT_ROOT; R=$S/takes/ads7-real; A2=$S/takes/ads2; B=$R/build
mkdir -p "$B"
ADS=$(python3 -c "import json;print(' '.join(json.load(open('$R/boards.json'))['spots']))")
for AD in $ADS; do
  ln -sfn "$R/$AD-vo" "$B/$AD-vo"; ln -sfn "$R/$AD-av" "$B/$AD-av"
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
# replace the hard-coded brand case block with one generated from boards.json
python3 - "$B/build-ad.sh" "$R" <<'PYB'
import json, re, sys
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
  ffmpeg -v error -y -i "$B/out-$AD-$AD-av/ad.mp4" -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -ar 48000 -ac 2 -c:a aac -b:a 192k -movflags +faststart "$RENDERS/ads7-$AD-final-v1.mp4"
done
echo "ads7 build complete"
