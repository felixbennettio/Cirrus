#!/bin/bash
# phones.sh <en|zh>: $OUT/<en|zh>/phone.png, the light and dark phone home
# screens (from batch.sh) side by side on a 1280x800 canvas.
set -e
APP=${APP:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "${OUT:-$APP/build/screenshots}/$1"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=680 R=34
prep() {  # rounded corners, a thin border and a soft shadow
  convert "$1" -resize x$H $T/r.png
  W=$(identify -format %w $T/r.png)
  convert $T/r.png \( -size ${W}x$H xc:none -fill white -draw "roundrectangle 0,0 $((W-1)),$((H-1)) $R,$R" \) \
    -alpha set -compose DstIn -composite \
    -fill none -stroke 'rgba(29,36,51,0.18)' -strokewidth 2 -compose Over -draw "roundrectangle 1,1 $((W-2)),$((H-2)) $R,$R" $T/rr.png
  convert $T/rr.png \( +clone -background '#1d2433' -shadow 20x16+0+12 \) +swap -background none -layers merge +repage "$2"
}
prep m-home.png $T/p1.png
prep m-home-dark.png $T/p2.png
convert -size 1280x800 gradient:'#f3f6fb'-'#e2e8f1' \
  $T/p1.png -gravity center -geometry -200+6 -composite \
  $T/p2.png -gravity center -geometry +200+6 -composite phone.png
echo "$PWD/phone.png"
