#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-notification-framer-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/AstraA1BleProtocol.swift \
  AIGlass/Bluetooth/AstraA1/AstraNotificationFramer.swift \
  Tests/AstraNotificationFramerTests.swift -o "$test_dir/notification-framer"
"$test_dir/notification-framer"
