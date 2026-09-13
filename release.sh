#!/bin/zsh
# Produces a signed, notarised, stapled DMG in dist/ for direct download.
#
# Requirements (one-time):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application, signed in as the team K465H4V2A2 account holder).
#   2. Notarisation credentials stored in the keychain:
#        xcrun notarytool store-credentials murmur-notary \
#          --apple-id you@example.com --team-id K465H4V2A2 \
#          --password <app-specific password from appleid.apple.com>
#
# Environment overrides:
#   MURMUR_DEVELOPER_ID   full identity string (default: first Developer ID
#                         Application cert in the keychain)
#   MURMUR_NOTARY_PROFILE notarytool keychain profile (default: murmur-notary)
#
# Usage: ./release.sh [--skip-notarize]
#   --skip-notarize builds and signs the DMG but does not submit it, useful
#   for checking the pipeline without an internet round trip.
set -euo pipefail
cd "$(dirname "$0")"

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

IDENTITY="${MURMUR_DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi
if [[ -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates, or set MURMUR_DEVELOPER_ID." >&2
    exit 1
fi
PROFILE="${MURMUR_NOTARY_PROFILE:-murmur-notary}"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DIST="dist"
STAGING="$DIST/staging"
APP="$DIST/Murmur.app"
DMG="$DIST/Murmur-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building and signing with: $IDENTITY"
MURMUR_SIGNING_IDENTITY="$IDENTITY" MURMUR_OUTPUT_DIR="$DIST" ./build.sh

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q audio-input || {
    echo "audio-input entitlement missing" >&2; exit 1; }

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo "==> Notarising the app"
    ditto -c -k --keepParent "$APP" "$DIST/Murmur-app.zip"
    xcrun notarytool submit "$DIST/Murmur-app.zip" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DIST/Murmur-app.zip"
fi

echo "==> Building DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Murmur.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Murmur $VERSION" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo "==> Notarising the DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

# The DMG is the deliverable. Leaving the intermediate bundle behind gives
# LaunchServices a second Murmur.app to register (it shows up twice in
# Spotlight and can be launched alongside the development build), so it is
# unregistered and removed.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Release ready: $DMG"
