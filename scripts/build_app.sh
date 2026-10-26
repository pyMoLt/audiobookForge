#!/bin/bash
# Builds an ad-hoc signed Release AudiobookForge, verifies the signature,
# and copies it to ../releases/ (or $DIST_DIR) and /Applications.
# A running instance is asked to quit first so the bundle isn't replaced
# underneath it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/../releases}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/audiobookforge-release}"
CONFIGURATION="${CONFIGURATION:-Release}"

cd "$PROJECT_DIR"
echo "==> tuist generate"
tuist generate --no-open

echo "==> xcodebuild build ($CONFIGURATION, ad-hoc signed)"
xcodebuild \
    -workspace AudiobookForge.xcworkspace \
    -scheme AudiobookForge \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_STYLE=Manual \
    build | grep -E "error:|Signing Identity|BUILD (SUCCEEDED|FAILED)" || true

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/AudiobookForge.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: build failed, no app at $APP_PATH"
    exit 1
fi

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

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
    ditto "$DIST_DIR/AudiobookForge.app" "/Applications/AudiobookForge.app"
    echo "==> Installed: /Applications/AudiobookForge.app"
fi

echo "==> Done. App is at: $DIST_DIR/AudiobookForge.app"
