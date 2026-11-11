# AI records and device entry implementation plan

**Goal:** Hide device execution phrases from AI records; use `model_name_alias` on pairing cards; retain the add-glasses card while connected; open password recovery directly for phone/email. Diagnose translation and password-code request failures with their supplied logs.

**Architecture:** Filter text while constructing history/live records, before timestamps. Match full known command phrases because historical responses lack command metadata. Keep media, speech playback and BLE execution intact. Decode optional model alias only for display, keeping raw model identifiers for pairing and API calls. Reuse the existing trailing find-device card and pairing action.

**Tech stack:** Swift, SwiftUI, Foundation; Windows static validation and macOS Swift test scripts.

**Spec:** User messages and screenshots in this conversation dated 2026-11-11.

## Constraints and review focus

- Preserve pending recording-duration fixes and build 1.1.6 (175).
- Chinese/English command phrases hidden; ordinary discussion/questions retained.
- Pictures/videos retained even when captions mention commands; filtered records add no timestamp.
- Missing/blank alias falls back to `model_name`; scan, bind and guide requests use raw name.
- Connected glasses remain first; adding is a trailing card using existing navigation.
- Distinguish text reception from returned speech; log evidence does not prove server vs network cause.

## Tasks

- [x] Add full-phrase text filter in `AIChatRecordFilter.swift`; integrate history, live text and image reply presentation; cover command/question boundaries with `Tests/AIChatRecordFilterTests.swift`.
- [x] Decode alias in `Network/DeviceService.swift`; use it in `DeviceSelectionView.swift`; verify optional decoding/fallback and unchanged API identifiers by source review.
- [x] Verify `AuthSession.homeDeviceCards`, `HomeDeviceSelection`, carousel and add action; retain card with connected devices and explicit button accessibility.
- [x] Summarize translation request lifecycle and audio-return events for 17:39 and 19:53 log sets. No confirmed new translation UI/protocol defect from these logs.
- [x] Remove navigation-time account validation from `LoginView.openForgotPassword`; use actual phone/email format to choose recovery mode, falling back to selected region for empty input. Reuse unauthenticated recovery with the title “修改密码”.
- [x] Correlate eight `user/send_code` timeouts with translation and userinfo failures. Add task metrics/default-path/error-chain observation in `Network/PublicHTTPDiagnostics.swift`, used by all five `APIClient` transports. Preserve sessions, request payloads, timeout, routing and retry behavior.
- [x] Run available syntax/whitespace/shell checks. macOS compilation, the Swift test executable and hardware checks remain explicitly unrun on Windows.

## Validation and remaining evidence

All 11 Swift files changed by these requests have no new tree-sitter syntax diagnostics relative to HEAD. New shell script passes `bash -n`; `git diff --check` passes; build stays 1.1.6 (175). Earlier recording-duration checks also still pass. The CI workflow includes the new command-filter regression executable for the next macOS build.

Reports: `../analysis/translation-20261111/findings.md` and `../analysis/translation-20261111/password-code-findings.md` in the workspace containing this repository. Network root cause remains unconfirmed: original logs do not contain transport milestones; the user confirms the network is another phone's hotspot, but web connectivity during failure is unknown.

## Packaging follow-up

The user subsequently requested packaging with build +1. Build is now 1.1.6 (176), using the established `debugging` export and test-device signing profile. The macOS workflow will run regression checks, compile, archive and export the pending recording-duration, AI-record, pairing-name, password-recovery and HTTP-diagnostics changes.
