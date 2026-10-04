#!/usr/bin/env bash
# Everything the "Simulator Screenshots" GitHub Actions job does, as one script,
# so the workflow file (.github/workflows/simulator-screenshots.yml) can stay a
# thin wrapper that never needs to change. The forum agent's token lacks the
# `workflow` scope, so edits under .github/workflows/ need a human; edits here
# don't.
#
#   scripts/ci/simulator-screenshots-job.sh            # build + capture
#
# Environment (all optional):
#   XCODE       path to the Xcode.app to use. Default: the newest
#               /Applications/Xcode_26*.app (HaishinKit 2.2+ needs Xcode 26;
#               GitHub's macos-15 image defaults to 16.4, which fails with
#               "cannot find 'kVTCompressionPropertyKey_VariableBitRate'").
#   DEVICE, SCENES, APPEARANCE, SETTLE   passed through to
#               scripts/simulator-screenshots.sh.
#   OUT         screenshot output dir (default: screenshots)
#
# Outputs: build/xcodebuild.log (always), $OUT/*.png (on success).
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=${OUT:-screenshots}
mkdir -p build "$OUT"

# --- Toolchain ---------------------------------------------------------------
if [ -z "${XCODE:-}" ]; then
  XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -n "${XCODE:-}" ] && [ -d "$XCODE" ]; then
  echo "Selecting $XCODE"
  sudo xcode-select -s "$XCODE"
else
  echo "No Xcode 26 found under /Applications; using the default toolchain" >&2
fi
xcodebuild -version
xcrun simctl list runtimes | grep -E '^iOS' || true

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

# --- Build -------------------------------------------------------------------
# Avoid buffering surprises: tee the full log, show only the interesting lines.
set +e
xcodebuild build \
  -project EveningsBroadcaster.xcodeproj \
  -scheme EveningsBroadcaster \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build/xcodebuild.log | grep -E 'error:|warning: .*(deprecated|unused)|\*\* BUILD' 
set -e
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' build/xcodebuild.log; then
  echo "::error::xcodebuild failed; see the xcodebuild-log artifact" >&2
  exit 1
fi

# --- Capture -----------------------------------------------------------------
scripts/simulator-screenshots.sh \
  build/DerivedData/Build/Products/Debug-iphonesimulator/Evenings.app \
  "$OUT"
ls -la "$OUT"
