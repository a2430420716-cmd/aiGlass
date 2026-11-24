#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-api-device-type.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 Tests/prepare-api-device-type-probe.py "$test_dir/models.swift"
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift AIGlass/Bluetooth/APIDeviceType.swift \
  AIGlass/Bluetooth/GlassDeviceModel.swift "$test_dir/models.swift" Tests/APIDeviceTypeTests.swift \
  -o "$test_dir/device-type"
"$test_dir/device-type"
