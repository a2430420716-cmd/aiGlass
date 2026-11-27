#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiglass-translation-language.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/cache" \
  AIGlass/Network/TranslationLanguage.swift Tests/TranslationLanguageTests.swift \
  -o "$test_dir/languages"
"$test_dir/languages" Tests/Fixtures/TranslationLanguagesAndroid.json
