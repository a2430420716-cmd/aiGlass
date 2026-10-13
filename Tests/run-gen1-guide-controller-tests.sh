#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-guide-controller.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

# Compile the actual controller without its SwiftUI view, replacing only external
# services in the test module. No source rewrite or real defaults/audio access.
awk '
  BEGIN { print "import Foundation" }
  /^import AVFoundation$/ || /^import SwiftUI$/ { next }
  /^\/\/\/ 交互式新手引导/ { exit }
  { print }
' AIGlass/NewbieGuideView.swift > "$test_dir/NewbieGuideController.swift"

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/Bluetooth/Gen1/Gen1GuideStepState.swift \
  "$test_dir/NewbieGuideController.swift" \
  Tests/Gen1GuideControllerTests.swift -o "$test_dir/gen1-guide-controller"
if "$test_dir/gen1-guide-controller" > "$test_dir/output.log" 2>&1; then
  tail -n 1 "$test_dir/output.log"
else
  cat "$test_dir/output.log"
  exit 1
fi
