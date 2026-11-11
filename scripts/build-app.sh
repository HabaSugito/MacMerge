#!/bin/sh
# Builds build/MacMerge.app.
#   UNIVERSAL=1   build for both Apple silicon and Intel (used for releases)
#   VERSION=1.2.3 version shown in About (default: latest git tag, or 0.1.0)
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/MacMerge
else
    swift build -c release
    BIN=.build/release/MacMerge
fi

APP=build/MacMerge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacMerge"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacMerge</string>
    <key>CFBundleDisplayName</key><string>MacMerge</string>
    <key>CFBundleIdentifier</key><string>io.github.habasugito.macmerge</string>
    <key>CFBundleExecutable</key><string>MacMerge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 HabaSugito. MIT License.</string>
</dict>
</plist>
PLIST
# Ad-hoc signature for local runs; scripts/release.sh signs with a Developer ID.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
