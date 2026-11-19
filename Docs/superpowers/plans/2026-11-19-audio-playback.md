# November 19 audio playback fixes

> Implement directly in this session under the user's existing authorization.

**Goal:** Let simultaneous interpretation play speech received while muted, and return music audio promptly after AI speech.

**Architecture:** Keep a bounded in-memory PCM buffer for the current interpretation recording. Enabling glasses sound replays that buffer in order; incoming speech then continues live. BLE voice capture does not need a phone audio session: activate exclusive audio only for actual AI playback, and release when all players and the existing 800 ms tail drain finish, independently of BLE listening state. Keep audio-owner checks.

**Tech Stack:** Swift 6, AVFoundation, existing Foundation state regressions and iOS 15 compilation checks.

**Spec:** November 19 interpretation logs/video (muted during all 20 speech chunks; enabled after stopping) and music logs/video (exclusive phone audio held through network waits and continued BLE listening).

## Constraints and review focus

- Preserve text translation, device commands, 800 ms tail draining, version and build.
- Store only this recording's returned PCM, at most 16 MB / 16,384 chunks; clear on next recording, language change or exit.
- Re-enabling sound replays the current recording from its beginning; disabling stops playback immediately. Never fall back to the phone speaker when glasses audio is required.
- Invalid/empty PCM, repeated toggles, new recordings, audio route failure, and buffer limits must not mix or grow recordings indefinitely.
- BLE listening, network waits and command-only replies must not hold phone playback audio. Active reply/bubble/drain players and a newer audio owner must remain protected.

## Tasks

- [x] Add bounded `TranslationSpeechReplayBuffer` and regressions in `TranslationAudioSessionState.swift` / `TranslationAudioSessionTests.swift`; cover ordering, replay without consumption, invalid PCM, cancellation, recording replacement and limits.
- [x] Integrate caching and replay into `SimultaneousTranslationController.swift`; stop old playback at recording replacement, preserve audio on playback failure, reset on language/exit.
- [x] Remove pre-activation from BLE capture in `AIVoiceChatManager.swift`; release after playback interruption/completion even when continuous BLE listening stays active.
- [x] Run native state/audio regressions and compile the actual controllers/managers for iOS 15, using stubs only for unrelated dependencies. Review production code paths for player and owner protection; perform syntax/diff checks. Physical Bluetooth/media regression remains required.

## Validation results

- Native Swift state regressions and existing microphone/PCM playback regressions passed.
- Exact production voice manager, simultaneous controller, conversation controller and translation manager compiled for iOS 15 under Swift 6 / MainActor isolation.
- Actual voice manager lifecycle regression passed: BLE-only listening never activates phone playback; reply completion releases during continuous listening; active remote/local/bubble/tail-drain players retain ownership; repeated completion releases once; a newer owner is protected; both hardware wake and incoming voice data release interrupted playback.
- Actual simultaneous controller regression passed with deterministic transport/microphone stubs: muted speech retained, enabling after Stop replays in order, late audio follows, off/on restarts the current recording, invalid PCM rejected, absent Bluetooth output blocked, route failure retry retained, and new recording/language/exit clear old speech.
- Native evidence: https://github.com/frankqianghe/AIGlass/actions/runs/44504883754. Verification inputs and SHA-256 manifest are under `analysis/audio-issues-20261119/verify/` outside the Git repository. All changed Swift files parsed; `git diff --check` passed.
- Physical Bluetooth playback and another app's music resumption still need device regression. The tests do not establish firmware or real audio routing behavior. Build remains 180.
