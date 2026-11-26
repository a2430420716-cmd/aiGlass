# Translation audio availability and phone-recording completion

> Execute sequentially in this session. Analysis and checks stay local; cloud is reserved for user-requested packaging.

**Goal:** Explain unavailable translation speech, retain a visible output control for translated text, and let phone recordings receive final speech before ending the service task.

**Architecture:** Keep BLE connectivity separate from the system audio route. Conversation messages derive replay availability from real PCM bytes. Reuse the existing bounded `TranslationFinishState` for phone capture, as already used for glasses capture. Keep simultaneous interpretation's switch limited to future incoming speech.

**Tech Stack:** SwiftUI, MainActor controllers, existing PCM replay and finish-state machinery.

## Evidence and constraints

- The 2026-11-26 simultaneous log receives translation text and PCM, but output remains Receiver/Speaker; the user also confirms system music cannot play through the glasses. Logs do not establish why the system audio link is unavailable.
- Conversation session C9532855 has translated text and an audio-done event without any received speech bytes. A later phrase is still pending when phone stop immediately sends `stop`; this is a separate risk of losing final speech.
- No fabricated TTS/audio, no phone-speaker fallback for glasses output, no replay when enabling the simultaneous switch.
- Keep version 1.1.7 (187). Preserve the unrelated OTA detail view edit. No packaging.

## Tasks

- [x] Show the correct destination icon for translated text; dim it when PCM is absent and give localized feedback on tap. Preserve recording guards and distinguish phone/glasses replay failures.
- [x] Wait for final speech after real phone capture, bounded by the existing 15-second finish deadline. Cancel a pending connection without starting that wait. Prevent a switch to glasses capture from closing a phone turn that is finishing.
- [x] Give both translation screens concrete Settings > Bluetooth and Control Center audio-output instructions when glasses playback fails.
- [x] Extend the existing production-method playback probe with conversation replay and phone-stop scenarios. Generate/parse it locally; native execution remains pending for the next requested package.
- [x] Verify changed Swift syntax, Python generation, shell syntax, diff whitespace, version and unrelated-file hash. Record limits honestly.

## Review focus

- Text-only, empty/odd PCM and audio arriving after text must yield accurate replay availability.
- Stopping active capture must wait; cancelling a connection must not leave a finishing gate stuck.
- Synchronous finish and timeout callbacks must release that gate.
- Missing Bluetooth output must not change the simultaneous switch or redirect glasses speech to the phone.
- Repeated taps while recording/finishing must not start replay.

## Local validation

- Tree-sitter Swift parsing: zero syntax errors in the three modified production files, the test source and the generated production-method probe.
- Probe generation completed successfully; the existing Bash runner passes `bash -n` and is already part of requested-package validation.
- `git diff --check` passes; version remains 1.1.7 (187); the unrelated OTA detail view retains SHA256 `cc13dc09ea495437842b1bc6044bc8d720d47ee38bca23f21553eb0097ebd317`.
- Windows has no Xcode/Swift compiler. Native test execution, full app compilation, rendered iOS UI and sound from physical glasses are **not verified**. No cloud tasks were dispatched.
