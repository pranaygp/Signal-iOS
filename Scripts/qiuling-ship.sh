#!/bin/bash
# Archive the Qiuling build of Signal and upload it to TestFlight, with no
# Xcode UI and no Apple ID prompt: signing and the upload both authenticate
# with an App Store Connect API key.
#
#   Scripts/qiuling-ship.sh            # archive + upload
#   Scripts/qiuling-ship.sh archive    # archive only (first run: registers the bundle IDs)
#
# Settings come from the environment, or from Config/qiuling.env (gitignored):
#   TEAM_ID          the 10-character Apple developer team ID
#   BUNDLE_PREFIX    reverse-DNS prefix for the bundle IDs, e.g. gp.pranay  (-> gp.pranay.q)
#   ASC_KEY_ID       App Store Connect API key ID
#   ASC_ISSUER_ID    App Store Connect API issuer ID
#   ASC_KEY_PATH     path to the AuthKey_XXXX.p8 file
#   QIULING_FONT_MANIFEST_URL, QIULING_FONT_BYPASS   (optional) where the app fetches font
#                    updates, and the trainer's Deployment Protection bypass token; baked
#                    into Info.plist. Without them the app only uses its bundled font.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Config/qiuling.env ] && source Config/qiuling.env
: "${TEAM_ID:?}" "${BUNDLE_PREFIX:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
# Build with the iOS 26 SDK. Signal has not adopted the UIScene lifecycle, and
# iOS 27 terminates any app linked against the iOS 27 SDK that has not
# (the crash is in UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption).
# Apps linked against iOS 26 run on iOS 27 unaffected, so pin the toolchain
# until upstream Signal adopts scenes. `xcodes install 26.6` provides it.
XCODE26=${XCODE26:-$(ls -d /Applications/Xcode-26.*.app 2>/dev/null | sort -V | tail -1)}
[ -n "$XCODE26" ] || { echo "no Xcode 26 found; run: xcodes install 26.6" >&2; exit 1; }
export DEVELOPER_DIR="$XCODE26/Contents/Developer"
echo "== using $(xcodebuild -version | tr '\n' ' ')"

# TestFlight needs a build number that only ever goes up; the minute is plenty.
BUILD=$(date -u +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Signal/Signal-Info.plist
for plist in SignalNSE/Info.plist SignalShareExtension/Info.plist; do
  [ -f "$plist" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist" || true
done
trap 'git checkout -q -- Signal/Signal-Info.plist SignalNSE/Info.plist SignalShareExtension/Info.plist 2>/dev/null || true' EXIT

# Signing uses the Apple ID signed into Xcode (Xcode > Settings > Accounts):
# Xcode's provisioning service rejects App Store Connect API keys here with a
# bare "Authentication failed" (tried Admin and App Manager keys), while the
# upload step accepts the same key without complaint.
SIGN_AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
UPLOAD_AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
ARCHIVE=build/Signal-Qiuling.xcarchive
rm -rf "$ARCHIVE"

# `xcodebuild archive` throws away its intermediates and rebuilds everything
# from scratch every run — fifteen-plus minutes for a one-line change. So the
# compile is an ordinary incremental `build` into a persistent DerivedData,
# and the .xcarchive is assembled by hand from the products; -exportArchive
# re-signs for distribution and uploads it exactly as it would a real one.
# Swift is set to incremental compilation too: App Store Release defaults to
# whole-module, which recompiles a whole module for any edit inside it.
DERIVED=build/DerivedData
PRODUCTS="$DERIVED/Build/Products/App Store Release-iphoneos"
echo "== building $BUILD as $BUNDLE_PREFIX.q"
xcodebuild build \
  -workspace Signal.xcworkspace -scheme Signal -configuration "App Store Release" \
  -destination generic/platform=iOS -derivedDataPath "$DERIVED" \
  "${SIGN_AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" SIGNAL_BUNDLEID_PREFIX="$BUNDLE_PREFIX" SIGNAL_MERCHANTID="" \
  QIULING_FONT_MANIFEST_URL="${QIULING_FONT_MANIFEST_URL:-}" QIULING_FONT_BYPASS="${QIULING_FONT_BYPASS:-}" \
  SWIFT_COMPILATION_MODE=incremental DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  | tee build/archive.log | grep -E "error:|warning: .*(Qiuling|provision)|\*\* BUILD" || true
[ -d "$PRODUCTS/Signal.app" ] && grep -q "BUILD SUCCEEDED" build/archive.log || { echo "build failed; see build/archive.log" >&2; exit 1; }

echo "== assembling $ARCHIVE"
mkdir -p "$ARCHIVE/Products/Applications" "$ARCHIVE/dSYMs"
cp -R "$PRODUCTS/Signal.app" "$ARCHIVE/Products/Applications/"
find "$PRODUCTS" -maxdepth 1 -name "*.dSYM" -exec cp -R {} "$ARCHIVE/dSYMs/" \;
APP_PLIST="$ARCHIVE/Products/Applications/Signal.app/Info.plist"
SIGNER=$(codesign -dvv "$ARCHIVE/Products/Applications/Signal.app" 2>&1 | sed -n 's/^Authority=\(Apple De[a-z]*: .*\)$/\1/p' | head -1)
cat > "$ARCHIVE/Info.plist" <<ARCHIVEPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Signal.app</string>
    <key>Architectures</key><array><string>arm64</string></array>
    <key>CFBundleIdentifier</key><string>$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PLIST")</string>
    <key>CFBundleShortVersionString</key><string>$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>SigningIdentity</key><string>$SIGNER</string>
    <key>Team</key><string>$TEAM_ID</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>Signal</string>
  <key>SchemeName</key><string>Signal</string>
</dict></plist>
ARCHIVEPLIST

[ "${1:-}" = archive ] && { echo "archived: $ARCHIVE"; exit 0; }

cat > build/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

echo "== uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/export.plist \
  -exportPath build/export "${UPLOAD_AUTH[@]}" | tee build/export.log | grep -E "error:|Upload succeeded|\*\* EXPORT" || true
grep -q "EXPORT SUCCEEDED" build/export.log || { echo "upload failed; see build/export.log" >&2; exit 1; }
echo "build $BUILD uploaded — it appears in TestFlight once Apple finishes processing (usually 5–15 min)"
