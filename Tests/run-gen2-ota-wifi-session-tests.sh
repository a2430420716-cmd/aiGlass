#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen2-ota-wifi.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Gen2OtaWifiConnectionSession.swift Tests/Gen2OtaWifiConnectionSessionTests.swift \
  -o "$test_dir/wifi-session"
"$test_dir/wifi-session"
