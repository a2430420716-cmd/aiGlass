# Translation final speech implementation plan

> Implement directly in this session; the user authorized the fix.

**Goal:** Preserve final translated speech when glasses recording stops so messages with returned audio retain their replay button.

**Architecture:** Separate stopping local capture from stopping the translation service. An opt-in finish state sends one second of PCM16 silence for VAD, drains final text/audio, then sends the existing stop command. Bound waiting to 15 seconds and cancel all finishing work on close/reconnect. Keep Gen1 device END draining intact.

**Tech Stack:** Swift, URLSessionWebSocketTask, existing Foundation state tests, native iOS simulator transport tests.

**Spec:** User report and November 19 logs: three recordings ended before translation_audio arrived; one completed audio before stop. User authorized this correction.

## Constraints and review focus

- Do not invent replay audio or display a usable replay button without received speech.
- Handle stop before VAD, already-completed speech, empty capture, missing completion, duplicate stop, and cancelled/replaced sessions.
- Finish only after ordered PCM/silence upload and final audio; a final text event alone is insufficient.
- Prevent a new conversation recording or language change from replacing a pending final result.
- Preserve existing immediate cancellation/error paths, physical Gen1 END handling, version and build.

## Tasks

- [x] Add deterministic `TranslationFinishState` regression coverage in `Tests/TranslationAudioSessionTests.swift`: no early stop, paced silence, completion/quiet interval, 15-second bound, empty input, duplicate finish and reset.
- [x] Implement that state in `AIGlass/Network/TranslationAudioSessionState.swift`; integrate opt-in graceful finish, result events, ordered silence sends, cancellation and completion callback in `RealtimeTranslationManager.swift`.
- [x] Use graceful finish for confirmed conversation glasses stops; preserve the current message while draining and release the gate on completion/error/exit in `ConversationTranslationController.swift`.
- [x] Run native state/audio regressions and attempt production-manager WebSocket scenarios for delayed speech, already completed speech, no response, cancellation/reconnect and duplicate stop. Check Swift syntax and whitespace; record practical limits below.

## Additional authorized request: home cards

- [x] Gate all eight home actions in `AIGlass/HomeView.swift` before commands, navigation, dialogs or generation-specific restrictions. Disconnected taps show exactly `设备未连接` / `Device not connected` through the existing alert, visible at every scroll position.
- [x] Allow disconnected buttons to receive taps for that alert; retain connected photo/video busy protection.
- [x] Verify all eight guards, bilingual copy, syntax and diff. Preserve the existing ready-and-bound-device availability policy.

- [x] Set the six home feature/guide subtitles to exact sRGB `#5F5F5F` using `AppTheme.homeCardSubtitleText` in `Theme.swift`. Keep the existing global secondary text token for other screens.

## Validation results

- Native Swift state regressions: **676 assertions passed**. Existing microphone conversion / PCM playback regressions passed.
- Exact production translation manager and conversation controller compiled for the iOS 15 simulator target under Swift 6 / MainActor isolation. Verification sources match the four-file SHA-256 manifest at `analysis/translation-finish-20261119/manifest.json` outside the repository.
- All six modified Swift files passed local Swift syntax parsing; all eight home action methods begin with the shared connection guard. Confirmed the six subtitles use the dedicated `#5F5F5F` token; diff whitespace check passed.
- Full simulated WebSocket scenarios remain **unverified**: the cloud simulator did not finish startup; the headless native client then timed out connecting to the loopback fixture before any recording/finish scenario ran. The fixture received no WebSocket handshake. This does not establish backend compatibility; physical glasses and the actual translation service still need regression testing.
- Native check evidence: https://github.com/frankqianghe/AIGlass/actions/runs/44497025392 (state/audio checks and iOS compilation passed; loopback transport check failed before exercising the fix).
- Version remains 1.1.6 (180). No package/export or real-device run performed.
