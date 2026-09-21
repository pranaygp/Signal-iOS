#!/bin/bash
# Build Qiuling for the simulator and open it straight onto the trainer, with
# none of Signal behind it (`-QiulingPracticeOnly 1`, see PracticeOnlyLaunch).
# Incremental into the same DerivedData the ship script uses, so a second run
# is a minute, not fifteen.
#
#   Scripts/qiuling-sim.sh              # build, install, launch on the trainer
#   Scripts/qiuling-sim.sh full         # launch the whole app instead (registration etc.)
#   SIM="iPhone 17 Pro" Scripts/qiuling-sim.sh
#   DERIVED=build/DerivedData-x NO_LAUNCH=1 Scripts/qiuling-sim.sh   # build only, in its own DerivedData
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Config/qiuling.env ] && source Config/qiuling.env
XCODE26=${XCODE26:-$(ls -d /Applications/Xcode-26.*.app 2>/dev/null | sort -V | tail -1)}
export DEVELOPER_DIR="$XCODE26/Contents/Developer"
SIM=${SIM:-iPhone 17 Pro Max}
DERIVED=${DERIVED:-build/DerivedData}
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Signal.app"
BUNDLE_PREFIX=${BUNDLE_PREFIX:-gp.pranay}

echo "== building for $SIM"
mkdir -p build
xcodebuild build \
  -workspace Signal.xcworkspace -scheme Signal -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DERIVED" \
  SIGNAL_BUNDLEID_PREFIX="$BUNDLE_PREFIX" SIGNAL_MERCHANTID="" CODE_SIGNING_ALLOWED=NO \
  QIULING_FONT_MANIFEST_URL="${QIULING_FONT_MANIFEST_URL:-}" QIULING_FONT_BYPASS="${QIULING_FONT_BYPASS:-}" \
  | tee "$DERIVED.log" | grep -E "error:|\*\* BUILD" || true
[ -d "$APP" ] && grep -q "BUILD SUCCEEDED" "$DERIVED.log" || { echo "build failed; see $DERIVED.log" >&2; exit 1; }
[ -n "${NO_LAUNCH:-}" ] && { echo "built $APP"; exit 0; }

UDID=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
[ -n "$UDID" ] || { echo "no simulator named $SIM" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
# Unsigned simulator builds can't enable the Safari extension; an ad-hoc
# signature over every nested bundle is enough for the simulator to trust it.
for f in "$APP"/Frameworks/*.framework "$APP"/PlugIns/*.appex; do codesign -f -s - "$f" 2>/dev/null; done
codesign -f -s - "$APP" 2>/dev/null
xcrun simctl install "$UDID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
if [ "${1:-}" = full ]; then
  xcrun simctl launch "$UDID" "$BUNDLE_ID"
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -QiulingPracticeOnly 1
fi
echo "running $BUNDLE_ID on $SIM ($UDID)"
