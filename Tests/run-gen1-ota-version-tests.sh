#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-ota-version.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Gen1FirmwareUpdateProtocol.swift \
  AIGlass/Gen1OtaVersionVerificationSession.swift \
  Tests/Gen1OtaVersionVerificationSessionTests.swift -o "$test_dir/gen1-ota-version"
"$test_dir/gen1-ota-version"
