#!/bin/zsh
# Build RenderDock and bundle it as a .app (command-line tools only, no Xcode needed). Output: build/RenderDock.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/RenderDock.app
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RenderDock "$APP/Contents/MacOS/RenderDock"
# The app draws its own icon: render a 1024 px PNG, then convert it to icns
ICON=build/AppIcon.icns
if [ ! -f "$ICON" ]; then
  T=$(mktemp -d)
  .build/release/RenderDock --icon "$T/icon.png"
  mkdir "$T/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
    sips -z $((s * 2)) $((s * 2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
  done
  iconutil -c icns "$T/AppIcon.iconset" -o "$ICON"
  cp "$T/icon.png" build/AppIcon.png
  rm -rf "$T"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.jarnoniu.renderdock</string>
    <key>CFBundleName</key><string>RenderDock</string>
    <key>CFBundleDisplayName</key><string>RenderDock</string>
    <key>CFBundleExecutable</key><string>RenderDock</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Built $PWD/$APP"
