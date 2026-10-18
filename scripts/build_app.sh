#!/bin/bash
# Builds a signed Release AudiobookForge (Personal Team, automatic signing),
# verifies the signature, and replaces dist/ and /Applications with it.
# A running instance is asked to quit first so the bundle isn't replaced
# underneath it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/AudiobookForge"
DIST_DIR="$ROOT_DIR/dist"
DERIVED_DATA="${DERIVED_DATA:-/tmp/audiobookforge-release}"
CONFIGURATION="${CONFIGURATION:-Release}"

cd "$PROJECT_DIR"
echo "==> tuist generate"
tuist generate --no-open

echo "==> xcodebuild build ($CONFIGURATION, signed)"
xcodebuild \
    -workspace AudiobookForge.xcworkspace \
    -scheme AudiobookForge \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    build | grep -E "error:|Signing Identity|BUILD (SUCCEEDED|FAILED)" || true

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/AudiobookForge.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: build failed, no app at $APP_PATH"
    exit 1
fi

echo "==> codesign verify"
codesign --verify --deep --strict "$APP_PATH"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" || {
    echo "ERROR: app is not signed with the development team"
    exit 1
}

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/AudiobookForge.app"
ditto "$APP_PATH" "$DIST_DIR/AudiobookForge.app"

if [ -d "/Applications" ] && [ -w "/Applications" ]; then
    if pgrep -x AudiobookForge >/dev/null; then
        echo "==> quitting running AudiobookForge"
        osascript -e 'tell application id "com.pymolt.AudiobookForge" to quit' || true
        for _ in $(seq 1 20); do pgrep -x AudiobookForge >/dev/null || break; sleep 0.5; done
    fi
    rm -rf "/Applications/AudiobookForge.app"
    ditto "$APP_PATH" "/Applications/AudiobookForge.app"
    echo "==> Installed: /Applications/AudiobookForge.app"
fi

echo "==> Done. App is at: $DIST_DIR/AudiobookForge.app"
