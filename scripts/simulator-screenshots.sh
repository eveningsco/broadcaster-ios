#!/usr/bin/env bash
# Boots an iOS simulator, installs a simulator build of the app, and captures
# one PNG per screenshot-mode scene (see Sources/Debug/ScreenshotMode.swift).
#
#   scripts/simulator-screenshots.sh <path/to/Evenings.app> <output dir>
#
# Environment:
#   DEVICE      simulator name to prefer (default: iPhone 16 Pro; falls back to
#               the first available iPhone on the newest iOS runtime)
#   SCENES      space-separated scenes (default: all)
#   APPEARANCE  light | dark | both (default: dark; the app forces its dark
#               palette via UIUserInterfaceStyle, so light looks the same)
#   SETTLE      seconds to wait after launch before capturing (default: 4)
#
# Needs Xcode (xcrun simctl) and python3; runs on a Mac or a macOS CI runner.
set -euo pipefail

APP=${1:?usage: $0 <Evenings.app> <output dir>}
OUT=${2:?usage: $0 <Evenings.app> <output dir>}
DEVICE=${DEVICE:-iPhone 16 Pro}
SCENES=${SCENES:-login signup library explore stage live}
APPEARANCE=${APPEARANCE:-dark}
SETTLE=${SETTLE:-4}
BUNDLE_ID=co.evenings.EveningsBroadcaster

mkdir -p "$OUT"

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)["devices"]
runtimes = sorted((k for k in data if "SimRuntime.iOS" in k),
                  key=lambda k: [int(p) for p in k.rsplit("iOS-", 1)[1].split("-")],
                  reverse=True)
for rt in runtimes:
    for d in data[rt]:
        if d["name"] == wanted and d.get("isAvailable", True):
            print(d["udid"]); sys.exit()
for rt in runtimes:
    for d in data[rt]:
        if d["name"].startswith("iPhone") and d.get("isAvailable", True):
            runtime = rt.rsplit(".", 1)[-1]
            print("%r not found; using %s (%s)" % (wanted, d["name"], runtime), file=sys.stderr)
            print(d["udid"]); sys.exit()
sys.exit("no available iPhone simulator")
' "$DEVICE")

echo "Using simulator $udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b

# Clean status bar (Apple's marketing-shot convention).
xcrun simctl status_bar "$udid" override \
  --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$udid" "$APP"

case "$APPEARANCE" in
  both) appearances="light dark" ;;
  light|dark) appearances="$APPEARANCE" ;;
  *) echo "APPEARANCE must be light, dark or both" >&2; exit 2 ;;
esac

for appearance in $appearances; do
  xcrun simctl ui "$udid" appearance "$appearance"
  for scene in $SCENES; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" -screenshot "$scene" >/dev/null
    sleep "$SETTLE"
    if [ "$appearances" = "light dark" ]; then
      file="$OUT/$scene-$appearance.png"
    else
      file="$OUT/$scene.png"
    fi
    xcrun simctl io "$udid" screenshot --type=png "$file" >/dev/null
    echo "captured $file"
  done
done

xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear
