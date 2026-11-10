#!/bin/sh
# Builds MacMerge.app into build/.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/MacMerge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacMerge "$APP/Contents/MacOS/MacMerge"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacMerge</string>
    <key>CFBundleDisplayName</key><string>MacMerge</string>
    <key>CFBundleIdentifier</key><string>io.github.habasugito.macmerge</string>
    <key>CFBundleExecutable</key><string>MacMerge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
