#!/bin/zsh
# Builds the Murmur binary with SwiftPM, then assembles and signs a proper
# .app bundle. A real bundle (with a stable bundle ID and signature) is what
# lets macOS remember the Microphone and Accessibility grants between builds.
#
# Signing: uses $MURMUR_SIGNING_IDENTITY if set, otherwise the first
# "Apple Development" certificate in your keychain, otherwise ad-hoc.
# Ad-hoc works, but macOS forgets permission grants on every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Murmur.app"

if [[ -z "${MURMUR_SIGNING_IDENTITY:-}" ]]; then
    MURMUR_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
fi
if [[ -z "${MURMUR_SIGNING_IDENTITY:-}" ]]; then
    MURMUR_SIGNING_IDENTITY="-"
    echo "No Apple Development certificate found; signing ad-hoc."
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$MURMUR_SIGNING_IDENTITY" "$APP"
echo "Built and signed $APP (identity: $MURMUR_SIGNING_IDENTITY)"
