#!/bin/zsh
# Build RenderDock, install it to Applications (/Applications) and relaunch it from there.
#   zsh scripts/install.sh           install only (if Launch at Login was on before, it is registered again afterwards)
#   zsh scripts/install.sh --login   install, and also turn on Launch at Login
# No admin password needed (/Applications is writable for admin users); no LaunchAgent is written, the login item uses the system's own registration.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Applications/RenderDock.app
BIN="$DEST/Contents/MacOS/RenderDock"

# Before reinstalling, note whether the login item is on: every build has a different ad-hoc signature, so it must be registered again after installing.
# The status text is matched in both UI languages (a previously installed copy may print either).
WAS_ON=0
[ -x "$BIN" ] && "$BIN" --login status 2>/dev/null | grep -qE "已开启|Enabled" && WAS_ON=1

zsh scripts/build-app.sh

# Ask the running copy to quit first (whether it is the one in the working tree or the installed one); wait up to 5 s
pkill -TERM -f "RenderDock.app/Contents/MacOS/RenderDock" 2>/dev/null || true
for i in {1..25}; do pgrep -f "RenderDock.app/Contents/MacOS/RenderDock" > /dev/null || break; sleep 0.2; done

rm -rf "$DEST"
ditto build/RenderDock.app "$DEST"
codesign --verify "$DEST"
echo "Installed $DEST"

if [[ "${1:-}" == "--login" || $WAS_ON == 1 ]]; then
  "$BIN" --login on
fi
open "$DEST"
echo "Launched. Launch at Login: $("$BIN" --login status)"
