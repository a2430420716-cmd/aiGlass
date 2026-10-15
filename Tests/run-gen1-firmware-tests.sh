#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-firmware-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Gen1FirmwareUpdateProtocol.swift Tests/Gen1FirmwareUpdateTests.swift \
  -o "$test_dir/protocol"
"$test_dir/protocol"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Gen1FirmwareUpdateProtocol.swift AIGlass/Gen1FirmwareUpdateSession.swift \
  Tests/Gen1FirmwareUpdateSessionTests.swift -o "$test_dir/session"
"$test_dir/session"
