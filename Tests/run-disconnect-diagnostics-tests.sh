#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-disconnect-diagnostics-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/ConnectionDiagnostics.swift \
  Tests/DisconnectDiagnosticsTests.swift -o "$test_dir/disconnect-diagnostics"
"$test_dir/disconnect-diagnostics"
