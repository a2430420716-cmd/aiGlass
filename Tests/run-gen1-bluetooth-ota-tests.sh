#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-bluetooth-ota.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Gen1BluetoothOtaSessionState.swift Tests/Gen1BluetoothOtaSessionStateTests.swift \
  -o "$test_dir/stages"
"$test_dir/stages"
