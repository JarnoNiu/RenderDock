#!/bin/zsh
# Regenerates everything in assets/: the icon, the screenshots and the demo GIFs (English and Chinese UI).
# All of it is drawn by the app in demo mode, so no screen recording is involved. Needs ffmpeg for the GIFs.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=.build/release/RenderDock
mkdir -p assets
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

"$BIN" --icon "$T/icon.png"
sips -z 512 512 "$T/icon.png" --out assets/icon.png > /dev/null

for lang in en zh; do
  "$BIN" --snapshot "$T" --demo --lang $lang > /dev/null
  cp "$T/capsule-$lang.png" "$T/panel-$lang.png" assets/
  "$BIN" --reel "$T/reel-$lang" --lang $lang > /dev/null
  out=assets/demo.gif
  [[ $lang == zh ]] && out=assets/demo-zh.gif
  ffmpeg -y -v error -framerate 15 -i "$T/reel-$lang/frame_%04d.png" \
    -vf "scale=1080:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    "$out"
done
ls -lh assets
