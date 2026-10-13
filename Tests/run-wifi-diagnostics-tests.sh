#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-wifi-diagnostics-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/WifiConnectionDiagnostics.swift \
  Tests/WifiConnectionDiagnosticsTests.swift -o "$test_dir/wifi-diagnostics"
"$test_dir/wifi-diagnostics"
