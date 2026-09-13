#!/bin/zsh
# Builds the Murmur binary with SwiftPM, then assembles and signs a proper
# .app bundle. A real bundle (with a stable bundle ID and signature) is what
# lets macOS remember the Microphone and Accessibility grants between builds.
#
# Signing: uses $MURMUR_SIGNING_IDENTITY if set, otherwise the first
# "Apple Development" certificate in your keychain, otherwise ad-hoc.
# Ad-hoc works, but macOS forgets permission grants on every rebuild.
#
# The bundle is always signed with the hardened runtime and the entitlements
# in Resources/Murmur.entitlements, so a development build behaves exactly
# like the notarised release. $MURMUR_OUTPUT_DIR overrides build/.
set -euo pipefail
cd "$(dirname "$0")"

OUT="${MURMUR_OUTPUT_DIR:-build}"
APP="$OUT/Murmur.app"

if [[ -z "${MURMUR_SIGNING_IDENTITY:-}" ]]; then
    MURMUR_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
fi
if [[ -z "${MURMUR_SIGNING_IDENTITY:-}" ]]; then
    MURMUR_SIGNING_IDENTITY="-"
    echo "No Apple Development certificate found; signing ad-hoc."
fi

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/Murmur.icns ]]; then
    cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
fi

SIGN_FLAGS=(--force --options runtime --entitlements Resources/Murmur.entitlements)
if [[ "$MURMUR_SIGNING_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" --sign "$MURMUR_SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built and signed $APP (identity: $MURMUR_SIGNING_IDENTITY)"
