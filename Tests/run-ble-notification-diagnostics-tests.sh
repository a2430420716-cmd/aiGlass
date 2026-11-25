#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-ble-notification-diagnostics-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/BLENotificationDiagnostics.swift \
  Tests/BLENotificationDiagnosticsTests.swift -o "$test_dir/notification-diagnostics"
"$test_dir/notification-diagnostics"

xcrun swiftc -D AIGLASS_DIAGNOSTICS -module-cache-path "$test_dir/cache" \
  AIGlass/Debug/AppDiagnostics.swift \
  AIGlass/Bluetooth/AstraA1/BLENotificationDiagnostics.swift \
  AIGlass/Bluetooth/AstraA1/AstraA1BleProtocol.swift \
  AIGlass/Debug/DebugLogStore.swift \
  Tests/BLERawLogStoreTests.swift -o "$test_dir/raw-log-store"
"$test_dir/raw-log-store"
