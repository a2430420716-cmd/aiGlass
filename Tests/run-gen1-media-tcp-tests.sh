#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-media-tcp-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -D GEN1_MEDIA_TCP_TESTING -module-cache-path "$test_dir/cache" \
  AIGlass/Album/AlbumTransferPolicy.swift \
  AIGlass/Album/Gen1MediaTCPProtocol.swift AIGlass/Album/Gen1MediaTCPClient.swift \
  Tests/Gen1MediaTCPTests.swift -o "$test_dir/gen1-media-tcp"
"$test_dir/gen1-media-tcp" "$@"
