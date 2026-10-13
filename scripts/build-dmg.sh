#!/bin/bash
# Builds, signs, notarizes and staples Nora.app and Nora-<version>.dmg into dist/.
#   scripts/build-dmg.sh              full release build
#   NOTARIZE=0 scripts/build-dmg.sh   signed but not notarized (local testing)
# Needs: App/Config/Local.xcconfig (DEVELOPMENT_TEAM), a Developer ID Application certificate,
# xcodegen, create-dmg, and the `nora-notary` notarytool keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
PROFILE="${NOTARY_PROFILE:-nora-notary}"
NOTARIZE="${NOTARIZE:-1}"
IDENTITY="Developer ID Application"

step() { printf '\n==> %s\n' "$*"; }

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$ROOT/App/Config/Local.xcconfig" 2>/dev/null | tr -d ' ')
[[ -n "$TEAM" ]] || { echo "Set DEVELOPMENT_TEAM in App/Config/Local.xcconfig" >&2; exit 1; }
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/App/Config/Nora.xcconfig" | tr -d ' ')

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

step "Generating the Xcode project"
(cd "$ROOT/App" && xcodegen generate --spec project.yml --quiet)

step "Archiving Nora $VERSION"
xcodebuild -project "$ROOT/App/Nora.xcodeproj" -scheme Nora -configuration Release \
    -derivedDataPath "$ROOT/build/DerivedData" -archivePath "$BUILD/Nora.xcarchive" \
    -destination 'generic/platform=macOS' archive -quiet

step "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$BUILD/Nora.xcarchive" -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$BUILD/export" -quiet
APP="$BUILD/export/Nora.app"

step "Verifying the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" >/dev/null

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m | tee "$BUILD/notary-$(basename "$1").log"
    grep -q 'status: Accepted' "$BUILD/notary-$(basename "$1").log"
}

if [[ "$NOTARIZE" == "1" ]]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$BUILD/Nora.zip"
    notarize "$BUILD/Nora.zip"
    xcrun stapler staple "$APP"
fi

step "Building the DMG"
DMG="$DIST/Nora-$VERSION.dmg"
rm -f "$DMG"
STAGE="$BUILD/dmg" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/"
create-dmg --volname "Nora" --window-size 560 380 --icon-size 128 \
    --icon "Nora.app" 150 185 --app-drop-link 410 185 --hide-extension "Nora.app" \
    --no-internet-enable "$DMG" "$STAGE" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$NOTARIZE" == "1" ]]; then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

step "Gatekeeper checks"
spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
shasum -a 256 "$DMG"
echo "Done: $DMG"
