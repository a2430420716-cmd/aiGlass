#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-ap-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
  AIGlass/Bluetooth/Gen1/Gen1APImportProtocol.swift \
  AIGlass/Album/Gen1ImportInbox.swift Tests/Gen1APImportTests.swift \
  -o "$test_dir/ap-import"
"$test_dir/ap-import"
