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
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Config/qiuling.env ] && source Config/qiuling.env
: "${TEAM_ID:?}" "${BUNDLE_PREFIX:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
case "$(xcode-select -p)" in */Xcode*.app/*) ;; *) echo "select Xcode first: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1;; esac

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

echo "== archiving build $BUILD as $BUNDLE_PREFIX.q"
xcodebuild archive \
  -workspace Signal.xcworkspace -scheme Signal -configuration "App Store Release" \
  -destination generic/platform=iOS -archivePath "$ARCHIVE" \
  "${SIGN_AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" SIGNAL_BUNDLEID_PREFIX="$BUNDLE_PREFIX" SIGNAL_MERCHANTID="" \
  CODE_SIGN_STYLE=Automatic PROVISIONING_PROFILE_SPECIFIER="" \
  | tee build/archive.log | grep -E "error:|warning: .*(Qiuling|provision)|\*\* ARCHIVE" || true
[ -d "$ARCHIVE" ] || { echo "archive failed; see build/archive.log" >&2; exit 1; }

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
