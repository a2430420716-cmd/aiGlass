#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-http-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/GlassesHTTPUploadResponse.swift \
  Tests/GlassesHTTPUploadResponseTests.swift -o "$test_dir/glasses-http"
"$test_dir/glasses-http"
