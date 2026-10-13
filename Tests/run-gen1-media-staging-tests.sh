#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-media-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/Gen1MediaStaging.swift \
  Tests/Gen1MediaStagingTests.swift -o "$test_dir/gen1-media"
"$test_dir/gen1-media"
