#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-home-video-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Bluetooth/AstraA1/AstraA1BleProtocol.swift \
  AIGlass/HomeVideoCaptureState.swift Tests/HomeVideoCaptureTests.swift \
  -o "$test_dir/home-video"
"$test_dir/home-video"
