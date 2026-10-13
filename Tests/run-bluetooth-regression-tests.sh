#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash Tests/run-gatt-recovery-tests.sh
bash Tests/run-astra-notification-framer-tests.sh
bash Tests/run-ble-notification-diagnostics-tests.sh
bash Tests/run-disconnect-diagnostics-tests.sh
bash Tests/run-gen2-ota-recovery-tests.sh
bash Tests/run-device-version-query-tests.sh
bash Tests/run-wifi-diagnostics-tests.sh
bash Tests/run-glasses-http-tests.sh
bash Tests/run-pairing-attempt-tests.sh
bash Tests/run-device-availability-tests.sh
bash Tests/run-device-command-availability-tests.sh

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-bluetooth-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/VoiceWakeupSettingState.swift Tests/VoiceWakeupSettingTests.swift \
  -o "$test_dir/voice-wakeup"
"$test_dir/voice-wakeup"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AIGlass/Network/TranslationAudioSessionState.swift Tests/TranslationAudioSessionTests.swift \
  -o "$test_dir/translation"
"$test_dir/translation"
