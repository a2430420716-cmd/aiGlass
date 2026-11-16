#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-firmware-download.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Network/FirmwareDownloadValidation.swift Tests/FirmwareDownloadValidationTests.swift \
  -o "$test_dir/validation"
"$test_dir/validation"
