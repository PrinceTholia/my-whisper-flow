#!/bin/bash
# Build a clean Whisper.app (no Sparkle) — better Accessibility TCC on ad-hoc builds
set -e
cd "$(dirname "$0")"

APP_NAME="WhisperApp"
APP_BUNDLE="Whisper.app"

echo "🔨 Building release..."
swift build -c release

echo "📦 Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "assets/Icon.icns" ]; then
    cp "assets/Icon.icns" "$APP_BUNDLE/Contents/Resources/Icon.icns"
fi
if [ -f "assets/logo.png" ]; then
    cp "assets/logo.png" "$APP_BUNDLE/Contents/Resources/logo.png"
fi

echo "✍️  Ad-hoc code signing (single binary, no nested frameworks)"
codesign --force --sign - --timestamp=none \
    --entitlements WhisperApp.entitlements \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - --timestamp=none \
    --entitlements WhisperApp.entitlements \
    "$APP_BUNDLE"

echo "✅ Done: $APP_BUNDLE"
echo "   open $APP_BUNDLE"
