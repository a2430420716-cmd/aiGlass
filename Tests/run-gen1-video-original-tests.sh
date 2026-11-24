#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-original.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/Gen1VideoOriginalValidator.swift Tests/Gen1VideoOriginalTests.swift \
  -o "$test_dir/original"
"$test_dir/original"
