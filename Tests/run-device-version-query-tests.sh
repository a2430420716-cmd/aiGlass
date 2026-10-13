#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-device-version-query-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/DeviceVersionQueryGate.swift \
  Tests/DeviceVersionQueryGateTests.swift -o "$test_dir/device-version-query"
"$test_dir/device-version-query"
