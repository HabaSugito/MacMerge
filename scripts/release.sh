#!/bin/sh
# Builds a signed, notarized build/MacMerge-<version>.dmg ready to publish.
#
# Signing:
#   SIGN_IDENTITY   code signing identity (default: "Developer ID Application")
# Notarization, either:
#   NOTARY_PROFILE  a keychain profile made with `xcrun notarytool store-credentials`
# or an App Store Connect API key (used by GitHub Actions):
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
# Testing the packaging without an Apple account:
#   SKIP_NOTARIZE=1 (ad-hoc signed, not for distribution)
set -eu
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build-app.sh
APP=build/MacMerge.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/MacMerge-$VERSION.dmg"

notarize() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    fi
}

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "SKIP_NOTARIZE=1: making an ad-hoc signed DMG for testing only"
else
    IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    # Notarize the app itself first so it carries its own ticket after it is copied out of the DMG.
    ZIP=build/MacMerge-notarize.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# The disk image: the app and a link to /Applications to drag it onto.
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacMerge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG"
echo "Created $DMG"
