#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-video-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror Tests/PixSmartVideoProfileTests.c -o "$test_dir/profile"
"$test_dir/profile"
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Album/Gen1VideoImportPipeline.swift Tests/Gen1VideoImportTests.swift -o "$test_dir/video"
"$test_dir/video"
