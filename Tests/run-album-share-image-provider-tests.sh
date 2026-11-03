#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-album-share-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor \
  -target "$(uname -m)-apple-macosx12.0" -module-cache-path "$test_dir/cache" \
  AIGlass/Album/AlbumShareImageProvider.swift \
  Tests/AlbumShareImageProviderTests.swift -o "$test_dir/album-share"
"$test_dir/album-share"
