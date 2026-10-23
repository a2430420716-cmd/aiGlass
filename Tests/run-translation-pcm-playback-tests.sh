#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-translation-pcm-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -module-cache-path "$test_dir/cache" \
  AIGlass/Network/TranslationPCMPlayback.swift \
  AIGlass/Network/TranslationAudioSessionState.swift \
  AIGlass/Network/TranslationMicrophoneProcessor.swift \
  Tests/TranslationMicrophoneTests.swift \
  Tests/TranslationPCMPlaybackTests.swift -o "$test_dir/translation-pcm-tests"
"$test_dir/translation-pcm-tests"
