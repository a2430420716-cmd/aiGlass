#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-unpair-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/FactoryResetConfirmation.swift \
  AIGlass/DeviceIdentityPresentation.swift \
  AIGlass/HomeDeviceSelection.swift \
  Tests/DeviceUnpairAndIdentityTests.swift -o "$test_dir/unpair-identity"
"$test_dir/unpair-identity"
