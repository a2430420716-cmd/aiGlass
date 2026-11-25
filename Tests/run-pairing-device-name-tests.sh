#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-pairing-names.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 Tests/prepare-pairing-device-name-probe.py "$test_dir/scan.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift AIGlass/Bluetooth/APIDeviceType.swift \
  AIGlass/Bluetooth/GlassDeviceModel.swift AIGlass/Bluetooth/PairingDeviceNamePolicy.swift \
  "$test_dir/scan.swift" Tests/PairingDeviceNamePolicyTests.swift \
  -o "$test_dir/names"
"$test_dir/names"
