#!/bin/bash
# Build a Release Scribe.app, ad-hoc sign it, and package .zip + .dmg.
# Works on any Apple Silicon Mac with Xcode 16+ (Xcode 26+ adds Apple Intelligence features)
# and on GitHub's macos-15 runners.
#   brew install xcodegen   # once
#   ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodegen generate
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [ -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]; then
  echo "SDK has FoundationModels: Apple Intelligence features compiled in"
else
  echo "SDK has NO FoundationModels: Apple Intelligence features compiled out (rules-only fallback)"
fi
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build > build/xcodebuild.log 2>&1 || { grep -E "error:|fatal" build/xcodebuild.log | sort -u | head -80; tail -30 build/xcodebuild.log; exit 1; }
echo "warnings: $(grep -c "warning:" build/xcodebuild.log || true)"
APP=build/DD/Build/Products/Release/Scribe.app
test -d "$APP" || { echo "build failed: no app"; exit 1; }
# Ad-hoc signature ("-") with the entitlements + hardened runtime. Not notarized:
# first launch needs right-click > Open (or System Settings > Privacy & Security > Open Anyway).
codesign --force --options runtime --entitlements Resources/Scribe.entitlements -s - "$APP"
codesign --verify --verbose=2 "$APP"
codesign -d --entitlements - "$APP" || true
mkdir -p dist
rm -rf dist/*
ditto -c -k --keepParent "$APP" dist/Scribe.zip
# DMG with an Applications shortcut so you can drag the app in.
mkdir -p build/dmg && rm -rf build/dmg/* && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname "Scribe" -srcfolder build/dmg -ov -format UDZO dist/Scribe.dmg
ls -la dist
