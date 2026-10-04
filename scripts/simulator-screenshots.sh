#!/usr/bin/env bash
# Boots an iOS simulator, installs a simulator build of the app, and captures
# one PNG per screenshot-mode scene (see Sources/Debug/ScreenshotMode.swift).
# Scenes ending in `-demo` animate, so they are *recorded* (simctl recordVideo)
# for VIDEO_SECONDS instead: the result is <scene>.mov plus <scene>.png, an
# animated PNG of the same clip. (APNG because the Simulator Screenshots
# workflow uploads `*.png`; it plays in any browser and converts to GIF/MP4
# with ffmpeg.)
#
#   scripts/simulator-screenshots.sh <path/to/Evenings.app> <output dir>
#
# Environment:
#   DEVICE         simulator name to prefer (default: iPhone 16 Pro; falls back
#                  to the first available iPhone on the newest iOS runtime)
#   SCENES         space-separated scenes (default: all stills; add edit-demo
#                  or track-demo for the editor / detail-card recordings)
#   APPEARANCE     light | dark | both (default: dark; the app forces its dark
#                  palette via UIUserInterfaceStyle, so light looks the same)
#   SETTLE         seconds to wait after launch before capturing (default: 4)
#   VIDEO_SECONDS  recording length for -demo scenes (default: 24)
#   VIDEO_FPS      animated-PNG frame rate (default: 15)
#   VIDEO_HEIGHT   animated-PNG height in px (default: 1300, ~half of a 3x
#                  iPhone; the .mov keeps full resolution)
#   FFMPEG         ffmpeg binary for the conversion. Default: `ffmpeg` on PATH,
#                  else a static build fetched once via `pip install
#                  imageio-ffmpeg` into a venv under $TMPDIR (GitHub's macOS
#                  images ship no ffmpeg). Set to "skip" to keep only the .mov.
#
# Needs Xcode (xcrun simctl) and python3; runs on a Mac or a macOS CI runner.
set -euo pipefail

APP=${1:?usage: $0 <Evenings.app> <output dir>}
OUT=${2:?usage: $0 <Evenings.app> <output dir>}
DEVICE=${DEVICE:-iPhone 16 Pro}
SCENES=${SCENES:-login signup library explore account edit track stage live}
APPEARANCE=${APPEARANCE:-dark}
SETTLE=${SETTLE:-4}
VIDEO_SECONDS=${VIDEO_SECONDS:-24}
VIDEO_FPS=${VIDEO_FPS:-15}
VIDEO_HEIGHT=${VIDEO_HEIGHT:-1300}
BUNDLE_ID=co.evenings.EveningsBroadcaster

# Prints the path of an ffmpeg to use, fetching a static build if needed.
ffmpeg_bin() {
  if [ -n "${FFMPEG:-}" ]; then echo "$FFMPEG"; return; fi
  if command -v ffmpeg >/dev/null; then command -v ffmpeg; return; fi
  local venv="${TMPDIR:-/tmp}/evenings-ffmpeg-venv"
  if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv" >&2
    "$venv/bin/pip" -q install imageio-ffmpeg >&2
  fi
  "$venv/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
}

# Animated PNG from a recording, looping forever.
to_apng() {
  local mov=$1 png=$2 ff
  ff=$(ffmpeg_bin) || { echo "no ffmpeg; keeping only $mov" >&2; return 0; }
  [ "$ff" = skip ] && return 0
  "$ff" -y -loglevel error -i "$mov" \
    -vf "fps=$VIDEO_FPS,scale=-1:$VIDEO_HEIGHT:flags=lanczos" \
    -plays 0 -f apng "$png"
}

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
    if [ "$appearances" = "light dark" ]; then
      base="$OUT/$scene-$appearance"
    else
      base="$OUT/$scene"
    fi
    case "$scene" in
      *-demo)
        # Start the recorder first and launch only once it reports
        # "Recording started": on GitHub's virtualised runners that takes
        # ~18 s, long enough for the whole demo to play unrecorded. It
        # finalises the file on SIGINT.
        xcrun simctl io "$udid" recordVideo --codec h264 --force "$base.mov" \
          > "$base.recorder.log" 2>&1 &
        recorder=$!
        for _ in $(seq 1 240); do
          grep -q "Recording started" "$base.recorder.log" 2>/dev/null && break
          kill -0 "$recorder" 2>/dev/null || break
          sleep 0.5
        done
        if ! grep -q "Recording started" "$base.recorder.log"; then
          echo "recorder never started for $scene:" >&2
          cat "$base.recorder.log" >&2
          exit 1
        fi
        xcrun simctl launch "$udid" "$BUNDLE_ID" -screenshot "$scene" >/dev/null
        sleep "$VIDEO_SECONDS"
        kill -INT "$recorder"
        wait "$recorder" || true
        cat "$base.recorder.log"
        rm -f "$base.recorder.log"
        [ -s "$base.mov" ] || { echo "recording $scene produced no file" >&2; exit 1; }
        echo "recorded $base.mov"
        to_apng "$base.mov" "$base.png"
        [ -s "$base.png" ] && echo "converted $base.png"
        ;;
      *)
        xcrun simctl launch "$udid" "$BUNDLE_ID" -screenshot "$scene" >/dev/null
        sleep "$SETTLE"
        xcrun simctl io "$udid" screenshot --type=png "$base.png" >/dev/null
        echo "captured $base.png"
        ;;
    esac
  done
done

xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear
