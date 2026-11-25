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
# The command line lives in Helpers: on a case-insensitive disk `renderdock` cannot sit next to `RenderDock` in MacOS/.
mkdir -p "$APP/Contents/Helpers"
cp .build/release/renderdock-cli "$APP/Contents/Helpers/renderdock"
# The Blender hook travels with the app, so there is a stable path to pass to --python.
cp blender/renderdock_hook.py "$APP/Contents/Resources/renderdock_hook.py"
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
    <key>CFBundleShortVersionString</key><string>0.3.1-dev</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>RenderDock uses Bluetooth only if you switch on "Connect a Bluetooth Device", to show progress on a small device on your desk.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/renderdock" 2>&1 | grep -v "replacing existing signature" || true
codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Built $PWD/$APP"
