#!/bin/zsh
# Fake render: a stand-in for a headless Blender job, for trying RenderDock without Blender or a GPU.
# It starts a do-nothing process named "blender" with real Blender arguments
# (-b file.blend -o //render/frame_#### -s 1 -e N -a) and drops one frame file per step.
#   zsh scripts/fake-render.sh [frames=40] [seconds-per-frame=0.5]
set -euo pipefail
N=${1:-40}
SPF=${2:-0.5}
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/project/render"
print '#include <unistd.h>\nint main(void) { for (;;) sleep(3600); }' > "$T/blender.c"
cc -o "$T/bin/blender" "$T/blender.c"
: > "$T/project/shot_010.blend"
cd "$T/project"
"$T/bin/blender" -b shot_010.blend -o //render/frame_#### -s 1 -e $N -a &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT INT TERM
for i in $(seq 1 $N); do
  sleep $SPF
  print -n fake > "render/frame_$(printf %04d $i).png"
done
sleep 3
