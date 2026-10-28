#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-gen1-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
protocol=AIGlass/Bluetooth/Gen1/Gen1Protocol.swift

xcrun swiftc -module-cache-path "$test_dir/cache" "$protocol" \
  Tests/Gen1ProtocolTests.swift -o "$test_dir/protocol"
"$test_dir/protocol"
bash Tests/run-gen1-control-diagnostics-tests.sh
bash Tests/run-gen1-guide-tests.sh
bash Tests/run-gen1-guide-controller-tests.sh
xcrun swiftc -module-cache-path "$test_dir/cache" "$protocol" \
  AIGlass/Bluetooth/AstraA1/AstraA1BleProtocol.swift \
  Tests/Gen1RuntimeStatusTests.swift -o "$test_dir/runtime-status"
"$test_dir/runtime-status"
xcrun swiftc -module-cache-path "$test_dir/cache" "$protocol" \
  AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift \
  Tests/Gen1CommandAdapterTests.swift -o "$test_dir/adapter"
"$test_dir/adapter"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Gen1FirmwareUpdateProtocol.swift Tests/Gen1FirmwareUpdateTests.swift \
  -o "$test_dir/firmware"
"$test_dir/firmware"
bash Tests/run-gen1-firmware-session-tests.sh
bash Tests/run-gen1-ota-version-tests.sh

bash Tests/run-gen1-ap-import-tests.sh
bash Tests/run-gen1-hotspot-cleanup-tests.sh
bash Tests/run-gen1-wifi-gateway-tests.sh
bash Tests/run-gen1-media-staging-tests.sh
bash Tests/run-photo-capture-watermark-tests.sh
bash Tests/run-gen1-media-tcp-tests.sh "$@"
bash Tests/run-gen1-video-import-tests.sh
