#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-diagnostics.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
ruby Tests/DiagnosticsBuildSettingsTests.rb
for variant in release debug testing mixed; do
  swift_flags=()
  objc_flags=()
  expected=enabled
  case "$variant" in
    release) expected=disabled ;;
    debug) swift_flags=(-D DEBUG); objc_flags=(-DDEBUG=1) ;;
    testing) swift_flags=(-D AIGLASS_DIAGNOSTICS); objc_flags=(-DAIGLASS_DIAGNOSTICS=1) ;;
    mixed) expected=disabled; swift_flags=(-D DEBUG -D AIGLASS_DIAGNOSTICS -D AIGLASS_PRODUCTION); objc_flags=(-DDEBUG=1 -DAIGLASS_DIAGNOSTICS=1 -DAIGLASS_PRODUCTION=1) ;;
  esac
  xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/cache" \
    ${swift_flags[@]+"${swift_flags[@]}"} AIGlass/Debug/AppDiagnostics.swift AIGlass/Debug/DebugLogStore.swift \
    AIGlass/Bluetooth/AstraA1/AstraA1BleProtocol.swift \
    AIGlass/Bluetooth/AstraA1/BLENotificationDiagnostics.swift Tests/DiagnosticsTests.swift \
    -o "$test_dir/$variant"
  "$test_dir/$variant" "$expected" > "$test_dir/$variant.txt"
  xcrun clang -fobjc-arc -framework Foundation ${objc_flags[@]+"${objc_flags[@]}"} Tests/DiagnosticsObjCTests.m -o "$test_dir/objc-$variant"
  "$test_dir/objc-$variant" "$expected" 2> "$test_dir/objc-$variant.txt"
  python3 - "$test_dir/$variant.txt" "$test_dir/objc-$variant.txt" "$expected" <<'PY'
import pathlib, sys
enabled = sys.argv[3] == 'enabled'
assert ('DIAGNOSTICS_CONSOLE_MARKER' in pathlib.Path(sys.argv[1]).read_text()) == enabled
assert ('DIAGNOSTICS_OBJC_MARKER' in pathlib.Path(sys.argv[2]).read_text()) == enabled
PY
  tail -1 "$test_dir/$variant.txt"
done
echo 'All diagnostics variants passed'
