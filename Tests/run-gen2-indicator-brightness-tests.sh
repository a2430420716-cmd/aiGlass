#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen2-brightness-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift \
  AIGlass/Bluetooth/AstraA1/AstraNotificationFramer.swift \
  AIGlass/Bluetooth/AstraA1/Gen2IndicatorBrightness.swift \
  Tests/Gen2IndicatorBrightnessTests.swift -o "$test_dir/brightness"
"$test_dir/brightness"
