#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-auth-account.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Auth/AuthAccountIdentifier.swift Tests/AuthAccountIdentifierTests.swift \
  -o "$test_dir/account"
"$test_dir/account"
