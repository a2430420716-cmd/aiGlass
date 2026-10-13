#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-control-diagnostics.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  Tests/Gen1ControlDiagnosticsTests.swift -o "$test_dir/control-diagnostics"
"$test_dir/control-diagnostics"
