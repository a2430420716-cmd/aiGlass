#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-ai-record-filter.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/AIChatRecordFilter.swift Tests/AIChatRecordFilterTests.swift \
  -o "$test_dir/filter"
"$test_dir/filter"
