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
# 0.7.3.1: the committed Package.resolved (repo root) pins the Swift packages for the build.
if [ -f Package.resolved ]; then
  mkdir -p Scribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  cp Package.resolved Scribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fi
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
  ${SCRIBE_VERSION:+MARKETING_VERSION=$SCRIBE_VERSION} ${SCRIBE_BUILD:+CURRENT_PROJECT_VERSION=$SCRIBE_BUILD} \
  build > build/xcodebuild.log 2>&1 || { grep -E "error:|fatal" build/xcodebuild.log | sort -u | head -80; tail -30 build/xcodebuild.log; exit 1; }
echo "warnings: $(grep -c "warning:" build/xcodebuild.log || true)"
APP=build/DD/Build/Products/Release/Scribe.app
test -d "$APP" || { echo "build failed: no app"; exit 1; }
# 0.7.3.1: Scribe has no text-to-speech. FluidAudio's LuxTTS G2P data (eSpeak NG output,
# GPL-3.0-or-later, and FrequencyWords keys, CC-BY-SA-4.0) is used only by its TTS, and its own
# notice says apps without TTS can leave it out. Strip that resource bundle before signing and
# fail if any of those files are still in the app.
echo "Resource bundles in the app:"; find "$APP" -maxdepth 4 -name "*.bundle" -print || true
find "$APP" -depth -name "*LuxTtsG2pResources*.bundle" -print -exec rm -rf {} +
LEFT=$(find "$APP" \( -iname "*luxtts*" -o -iname "*espeak*" -o -iname "*en_full*" \) -print)
if [ -n "$LEFT" ]; then echo "::error::TTS resources still in Scribe.app:"; echo "$LEFT"; exit 1; fi
echo "TTS_STRIP_CHECK ok: no LuxTTS / eSpeak NG / FrequencyWords files in Scribe.app"
# 0.7.3.1 Credits & licenses: every resolved Swift package must have a license entry, and every
# license file must be in the bundle. The resolved versions ship next to them (before signing).
RESOLVED=Scribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
[ -f "$RESOLVED" ] || RESOLVED=$(find Scribe.xcodeproj build/SourcePackages -maxdepth 4 -name Package.resolved 2>/dev/null | head -1 || true)
echo "Package.resolved: ${RESOLVED:-not found}"
if [ -n "$RESOLVED" ] && [ -f "$RESOLVED" ]; then
  cp "$RESOLVED" "$APP/Contents/Resources/Licenses/Package.resolved"
  cat "$RESOLVED"
fi
python3 scripts/check_licenses.py "${RESOLVED:-missing}" "$APP/Contents/Resources/Licenses"
# 0.7.3.2 accounts: fill the bundled Supabase.plist (placeholders in git) from the build
# environment, BEFORE signing. Unset = accounts stay off ("Accounts coming soon").
if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :SupabaseURL $SUPABASE_URL" -c "Set :SupabaseAnonKey $SUPABASE_ANON_KEY" \
    "$APP/Contents/Resources/Supabase.plist"
  echo "Accounts: Supabase URL + anon key set from the build environment"
else
  echo "Accounts: not configured (placeholders) -> the app shows 'Accounts coming soon'"
fi
# Signing. Not notarized either way: first launch needs right-click > Open (or System Settings >
# Privacy & Security > Open Anyway).
#  • If SIGNING_CERT_P12 (base64 of a .p12) + SIGNING_CERT_PASSWORD are set (GitHub secrets), sign
#    with that self-signed "Code Signing" certificate. The app's identity then stays the SAME
#    across updates, so macOS keeps the Accessibility permission (README → Signing).
#  • Otherwise: ad-hoc ("-"). macOS sees every build as a new app → Accessibility must be
#    removed and re-added after each update.
IDENTITY="-"
if [ -n "${SIGNING_CERT_P12:-}" ] && [ -n "${SIGNING_CERT_PASSWORD:-}" ]; then
  KC="$PWD/build/signing.keychain-db"; KCPW="scribe-$RANDOM-$RANDOM"
  # The secret may be hex (preferred: no "/" or "+" for a browser to mangle) or base64.
  P12CLEAN=$(printf '%s' "$SIGNING_CERT_P12" | tr -d ' \n\r\t')
  if printf '%s' "$P12CLEAN" | grep -Eq '^[0-9a-fA-F]+$'; then
    printf '%s' "$P12CLEAN" | xxd -r -p > build/signing.p12
  else
    printf '%s' "$P12CLEAN" | base64 --decode > build/signing.p12 || { echo "::warning::SIGNING_CERT_P12 is not valid hex/base64"; : > build/signing.p12; }
  fi
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  if security import build/signing.p12 -k "$KC" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign -f pkcs12; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
    # Self-signed = not "valid" in the trust sense, so list ALL code-signing identities, take its SHA-1.
    IDENTITY=$(security find-identity -p codesigning "$KC" | grep -Eo '[0-9A-F]{40}' | head -1 || true)
  fi
  rm -f build/signing.p12
  [ -z "$IDENTITY" ] && IDENTITY="-"
fi
if [ "$IDENTITY" != "-" ] && codesign --force --options runtime --entitlements Resources/Scribe.entitlements \
     --keychain "$KC" -s "$IDENTITY" "$APP"; then
  echo "SIGNED with the stable self-signed certificate ($IDENTITY)"
else
  [ "$IDENTITY" != "-" ] && echo "::warning::Signing with SIGNING_CERT_P12 failed; falling back to ad-hoc"
  codesign --force --options runtime --entitlements Resources/Scribe.entitlements -s - "$APP"
  echo "SIGNED ad-hoc"
fi
codesign --verify --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true
# The app icon must be in the bundle (Dock/Finder): Assets.car + CFBundleIconName.
test -f "$APP/Contents/Resources/Assets.car" || { echo "missing Assets.car (app icon)"; exit 1; }
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
codesign -d --entitlements - "$APP" || true
mkdir -p dist
rm -rf dist/*
ditto -c -k --keepParent "$APP" dist/Scribe.zip
# Checksum the updater verifies before installing.
(cd dist && shasum -a 256 Scribe.zip > Scribe.zip.sha256 && cat Scribe.zip.sha256)
# DMG with an Applications shortcut so you can drag the app in.
mkdir -p build/dmg && rm -rf build/dmg/* && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname "Scribe" -srcfolder build/dmg -ov -format UDZO dist/Scribe.dmg
(cd dist && shasum -a 256 Scribe.zip Scribe.dmg > SHA256SUMS.txt)
ls -la dist
