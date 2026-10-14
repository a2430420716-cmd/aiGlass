#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-media-directory-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Album/GlassesMediaDirectory.swift Tests/GlassesMediaDirectoryTests.swift \
  -o "$test_dir/media-directory"
"$test_dir/media-directory"
