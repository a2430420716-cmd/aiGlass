#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gatt-recovery-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/GATTRecoveryPolicy.swift \
  Tests/GATTRecoveryTests.swift -o "$test_dir/gatt-recovery"
"$test_dir/gatt-recovery"

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/BluetoothActivationPolicy.swift \
  Tests/BluetoothActivationPolicyTests.swift -o "$test_dir/bluetooth-activation"
"$test_dir/bluetooth-activation"
