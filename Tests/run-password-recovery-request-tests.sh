#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-password-recovery.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Network/AuthService.swift Tests/PasswordRecoveryRequestTests.swift \
  -o "$test_dir/password-recovery"
"$test_dir/password-recovery"
