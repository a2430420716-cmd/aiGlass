#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-pairing-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/PairingAttemptState.swift Tests/PairingAttemptStateTests.swift \
  -o "$test_dir/pairing-attempt"
"$test_dir/pairing-attempt"
