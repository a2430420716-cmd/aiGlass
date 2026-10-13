#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-device-availability.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/DeviceAvailabilityPolicy.swift Tests/DeviceAvailabilityPolicyTests.swift \
  -o "$test_dir/device-availability"
"$test_dir/device-availability"
