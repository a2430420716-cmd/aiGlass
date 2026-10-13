#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-device-command-availability-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/DeviceCommandAvailabilityPolicy.swift \
  Tests/DeviceCommandAvailabilityPolicyTests.swift -o "$test_dir/device-command-availability"
"$test_dir/device-command-availability"
