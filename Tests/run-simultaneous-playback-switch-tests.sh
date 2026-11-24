#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-simultaneous-switch.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 Tests/prepare-simultaneous-playback-probe.py \
  "${1:-AIGlass/SimultaneousTranslationController.swift}" \
  "${2:-AIGlass/Network/TranslationAudioSessionState.swift}" "$test_dir/controller.swift"
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Network/SimultaneousTranslationRecordStore.swift \
  "$test_dir/controller.swift" Tests/SimultaneousPlaybackSwitchTests.swift \
  -o "$test_dir/switch"
"$test_dir/switch"
