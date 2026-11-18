#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage="test/make-effect-strips.sh
  Renders the picture strips in docs/effects/ that docs/effects.md links, with the app's own renderer
  (./exact-studio strip), on a made-up window recording. Run it after a change to how anything draws,
  then look at the strips and commit them."
case "${1:-}" in -h|--help) echo "$usage"; exit 0 ;; "") ;; *) echo "$usage" >&2; exit 2 ;; esac

work=.exact/strips
lib=$work/lib
rec=$lib/fx
out=docs/effects
rm -rf "$lib"
mkdir -p "$rec/images" "$out"
rm -f "$out"/*.png

if [ ! -f "$work/capture.mov" ] || [ test/strip-video.swift -nt "$work/capture.mov" ]; then
  swiftc -O -suppress-warnings -o "$work/strip-video" test/strip-video.swift
  "$work/strip-video" "$work/capture.mov"
fi
cp "$work/capture.mov" "$rec/capture.mov"
cp test/fixtures/media/logo.png "$rec/images/logo.png"

cat > "$rec/meta.json" <<'EOF'
{ "id": "fx", "name": "Effect strips", "kind": "window", "created": 1700000000, "duration": 10,
  "width": 640, "height": 360, "crop": { "x": 0, "y": 0, "w": 1, "h": 1 }, "cursorBaked": false,
  "clicks": [ { "t": 2.0, "x": 0.6, "y": 0.76 } ] }
EOF
awk 'BEGIN { printf "["; for (i = 0; i <= 100; i++) { t = i / 10; u = (t < 5 ? t / 5 : 1); v = (t < 5 ? 0 : (t - 5) / 5);
  x = 0.15 + 0.45 * u - 0.2 * v; y = 0.25 + 0.51 * u - 0.06 * v;
  printf "%s{\"t\":%.1f,\"x\":%.3f,\"y\":%.3f}", (i ? "," : ""), t, x, y } print "]" }' > "$rec/cursor.json"

plain='{ "aspect": "16:9", "background": "custom", "customA": "#2B2D33", "customB": "#2B2D33", "shadow": false, "padding": 8 }'
room='"base": { "x": 0.5, "y": 0.6, "scale": 0.72 }'

strip() {
  local name=$1 from=$2 to=$3 frames=$4 width=$5 edits=$6 look=${7:-$plain} time=${8:-source}
  echo "{ \"lanes\": 3, \"textLanes\": 3, \"imageLanes\": 1, \"frameLanes\": 1, $edits }" > "$rec/edits.json"
  echo "$look" > "$rec/look.json"
  ./exact-studio validate fx --library "$lib" > /dev/null || { ./exact-studio validate fx --library "$lib"; exit 1; }
  ./exact-studio strip fx "$from" "$to" --frames "$frames" --width "$width" --out "$out/$name.png" --library "$lib" \
    $([ "$time" = source ] && echo --source) > /dev/null
  echo "$out/$name.png"
}

seg() { echo "\"segments\": [ $1 ]"; }
text() { echo "{ \"id\": \"$1\", \"kind\": \"text\", \"start\": $2, \"end\": $3, \"lane\": 0, \"text\": \"Hello world\", \"x\": 0.5, \"y\": 0.13, \"size\": 0.12, \"weight\": \"heavy\", \"style\": \"pill\", $4 }"; }
image() { echo "{ \"id\": \"$1\", \"kind\": \"image\", \"start\": $2, \"end\": $3, \"lane\": 0, \"file\": \"images/logo.png\", $4 }"; }
centre='"x": 0.5, "y": 0.5, "size": 0.35'
still='"animIn": "none", "animOut": "none"'

e='{ "id": "z", "kind": "zoom", "start": 1, "end": 5, "level": 2 }'
strip zoom-in 0.9 5.1 6 960 "$(seg "$e")"
e='{ "id": "z", "kind": "zoom", "start": 1, "end": 5, "level": 0.7 }'
strip zoom-out 0.9 5.1 6 960 "$(seg "$e")"
e='{ "id": "s", "kind": "spotlight", "start": 1, "end": 5 }'
strip spotlight 0.9 2.5 5 960 "$(seg "$e")"
e='{ "id": "h", "kind": "highlight", "start": 1, "end": 5 }'
strip highlight 0.9 2.5 5 960 "$(seg "$e")"
t=$(text t 0.2 9.8 "$still, \"color\": \"yellow\"")
i=$(image i 0.2 9.8 "\"x\": 0.82, \"y\": 0.75, \"size\": 0.25, $still")
for fx in blur mono; do
  e="{ \"id\": \"e\", \"kind\": \"$fx\", \"start\": 1, \"end\": 5 }"
  strip "$fx-video" 0.8 1.6 4 960 "$room, $(seg "$e, $t, $i")"
  for scope in frame all; do
    e="{ \"id\": \"e\", \"kind\": \"$fx\", \"scope\": \"$scope\", \"start\": 1, \"end\": 5 }"
    strip "$fx-$scope" 0.8 1.6 4 960 "$room, $(seg "$e, $t, $i")"
  done
done
colourful='{ "aspect": "16:9", "background": "sunset", "shadow": false, "padding": 8 }'
for fx in blur mono; do
  for scope in background scene; do
    e="{ \"id\": \"e\", \"kind\": \"$fx\", \"scope\": \"$scope\", \"start\": 1, \"end\": 5 }"
    strip "$fx-$scope" 0.8 1.6 4 960 "$room, $(seg "$e, $t, $i")" "$colourful"
  done
done
e='{ "id": "d", "kind": "3d", "start": 1, "end": 5, "style": "hold", "tilt": 12, "turn": -28, "roll": 0 }'
strip 3d-hold 1 5 6 960 "$(seg "$e")"
e='{ "id": "d", "kind": "3d", "start": 1, "end": 5, "style": "orbit", "tilt": 8, "roll": 0 }'
strip 3d-orbit 1 5 9 1152 "$(seg "$e")"
r='"rect": { "x": 0.27, "y": 0.14, "w": 0.4, "h": 0.17 }'
e="{ \"id\": \"m1\", \"kind\": \"mask\", \"start\": 1, \"end\": 3, $r, \"style\": \"blur\" }, { \"id\": \"m2\", \"kind\": \"mask\", \"start\": 3.5, \"end\": 5.5, $r, \"style\": \"pixels\" }, { \"id\": \"m3\", \"kind\": \"mask\", \"start\": 6, \"end\": 8, $r, \"style\": \"solid\", \"radius\": 0.3 }"
strip mask-styles 2 7 3 768 "$(seg "$e")"
for kind in crossfade fade; do
  e="\"splits\": [3, 5], \"removed\": [3], \"transitions\": { \"3000\": \"$kind\" }, \"base\": { \"x\": 0.35, \"y\": 0.5, \"scale\": 0.6 }, \"moves\": [ { \"id\": \"m\", \"t\": 5.01, \"to\": { \"x\": 0.65, \"y\": 0.5, \"scale\": 0.6 }, \"style\": \"linear\", \"duration\": 0.01 } ]"
  [ "$kind" = crossfade ] && span="2.3 3.1" || span="2.5 3.5"
  strip "transition-$kind" $span 6 1152 "$e" "$plain" video
done

for style in smooth linear spring zoom swipe fade spin pop; do
  strip "move-$style" 1.4 3.2 7 1120 "\"moves\": [ { \"id\": \"m\", \"t\": 3, \"to\": { \"x\": 0.3, \"y\": 0.55, \"scale\": 0.55 }, \"style\": \"$style\", \"duration\": 1.5 } ]"
done
strip move-spin-3d 1.4 3.2 7 1120 '"three": { "on": true, "tilt": 0, "turn": 0, "roll": 0 }, "moves": [ { "id": "m", "t": 3, "to": { "x": 0.5, "y": 0.5, "scale": 0.8 }, "style": "spin", "duration": 1.5, "angles": { "tilt": 8, "turn": 0, "roll": 0 } } ]'
strip move-3d-angles 1.4 3.2 7 1120 '"three": { "on": true, "tilt": 0, "turn": 0, "roll": 0 }, "moves": [ { "id": "m", "t": 3, "to": { "x": 0.5, "y": 0.5, "scale": 0.8 }, "style": "smooth", "duration": 1.5, "angles": { "tilt": 15, "turn": 30, "roll": 0 } } ]'

for a in fade pop rise blur spin slide letters letters-pop drop typewriter; do
  case $a in letters*|drop|typewriter) to=2.1 ;; *) to=1.6 ;; esac
  t=$(text t 1 9 "\"animIn\": \"$a\", \"animOut\": \"none\"")
  strip "text-in-$a" 1 "$to" 6 1200 "$room, $(seg "$t")"
done
for a in fade pop sink blur fall letters; do
  t=$(text t 0.5 3 "\"animIn\": \"none\", \"animOut\": \"$a\"")
  strip "text-out-$a" 2.4 2.98 6 1200 "$room, $(seg "$t")"
done
for l in wave pulse float wiggle; do
  t=$(text t 1 9 "$still, \"loop\": \"$l\"")
  strip "text-loop-$l" 2 3.4 6 1200 "$room, $(seg "$t")"
done
row() {
  local field=$1 y=$2 list="" i=0 v a b
  shift 2
  for v in "$@"; do
    a=$(awk "BEGIN { print $i * 1.6 + 0.1 }"); b=$(awk "BEGIN { print $i * 1.6 + 1.5 }")
    list+="${list:+, }{ \"id\": \"t$i\", \"kind\": \"text\", \"start\": $a, \"end\": $b, \"text\": \"$v\", \"x\": 0.5, \"y\": $y, \"size\": 0.16, $([ "$field" = weight ] || echo "\"weight\": \"heavy\",") \"$field\": \"$v\", $still }"
    i=$((i + 1))
  done
  seg "$list"
}
strip text-styles 0.8 7.2 5 1200 "$room, $(row style 0.13 plain pill box outline shadow)" '{ "aspect": "16:9", "background": "steel", "shadow": false, "padding": 8 }'
strip text-weights 0.8 5.6 4 960 "$room, $(row weight 0.13 regular bold heavy rounded)"
strip text-colors 0.8 8.8 6 1200 "$room, $(row color 0.13 white black yellow pink blue mint)" '{ "aspect": "16:9", "background": "steel", "shadow": false, "padding": 8 }'

for a in fade pop rise blur spin slide; do
  i=$(image i 1 9 "$centre, \"animIn\": \"$a\", \"animOut\": \"none\"")
  strip "image-in-$a" 1 1.6 6 960 "$(seg "$i")"
done
for a in fade pop sink blur; do
  i=$(image i 0.5 3 "$centre, \"animIn\": \"none\", \"animOut\": \"$a\"")
  strip "image-out-$a" 2.55 2.98 5 960 "$(seg "$i")"
done
for fx in blur mono fade pulse float wiggle; do
  case $fx in blur|mono|fade) from=1.9 to=2.4 n=4 ;; *) from=2.5 to=3.6 n=5 ;; esac
  i=$(image i 0.5 9.5 "$centre, $still, \"effects\": [ { \"id\": \"e\", \"kind\": \"$fx\", \"start\": 2, \"end\": 6 } ]")
  strip "image-effect-$fx" "$from" "$to" "$n" 960 "$(seg "$i")"
done

for fx in blur mono fade; do
  t="{ \"id\": \"t\", \"kind\": \"text\", \"start\": 0.5, \"end\": 9.5, \"text\": \"Hello world\", \"x\": 0.5, \"y\": 0.5, \"size\": 0.14, \"weight\": \"heavy\", \"style\": \"pill\", \"color\": \"yellow\", $still, \"effects\": [ { \"id\": \"e\", \"kind\": \"$fx\", \"start\": 2, \"end\": 6 } ] }"
  strip "text-effect-$fx" 1.9 2.4 4 960 "$(seg "$t")"
done

du -ch "$out"/*.png | tail -1
