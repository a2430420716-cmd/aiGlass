#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen2-ota-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/Gen2OtaRecoveryState.swift Tests/Gen2OtaRecoveryStateTests.swift \
  -o "$test_dir/gen2-ota-recovery"
"$test_dir/gen2-ota-recovery"
