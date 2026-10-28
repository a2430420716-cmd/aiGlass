#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-watermark-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/PhotoCaptureWatermarkStore.swift \
  Tests/PhotoCaptureWatermarkTests.swift -o "$test_dir/watermarks"
"$test_dir/watermarks"
