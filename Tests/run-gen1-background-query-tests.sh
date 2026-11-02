#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-background-query.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1BackgroundQueryGate.swift \
  Tests/Gen1BackgroundQueryGateTests.swift -o "$test_dir/query-gate"
"$test_dir/query-gate"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift \
  Tests/Gen1CommandAdapterTests.swift -o "$test_dir/adapter"
"$test_dir/adapter"
