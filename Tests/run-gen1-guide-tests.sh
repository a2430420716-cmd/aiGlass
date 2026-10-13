#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-guide-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/Bluetooth/Gen1/Gen1GuideStepState.swift \
  Tests/Gen1GuideStepStateTests.swift -o "$test_dir/gen1-guide"
"$test_dir/gen1-guide"
