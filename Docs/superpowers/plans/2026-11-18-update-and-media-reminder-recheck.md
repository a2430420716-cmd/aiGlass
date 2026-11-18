# Android update and media reminder recheck

**Goal:** Recheck the device update reminder and photo/video messages against `glasses(2).zip`.

**Architecture:** Retain the existing offer coordinator, upgrade detail flow and device-confirmed recording state. Correct presentation, server metadata and ordinary-offer eligibility in place.

**Constraints:** Preserve current local display fixes. No build increment, packaging or OTA transport changes. Execute directly in this session.

- [x] Match Android update titles, introduction and empty release notes. Decode `en_content`, use it for English with Chinese fallback in both reminder and detail views.
- [x] Retain ordinary cancellation and backend `is_forced` behavior; reject ordinary offers with an empty download URL or placeholder local version. Keep interrupted-upgrade recovery independent.
- [x] Keep the three Android photo/video messages, emit each action reminder once, and preserve device confirmation before recording success feedback.
- [x] Check Swift syntax/diff, model decoding and ordinary-offer gates; run existing recording-state regressions. Physical device behavior requires follow-up verification.

Validation:
- Actual Android Chinese/English resources match the reminder titles, introduction, empty notes and all three media messages.
- Source checks confirm exactly one assignment per action message. BLE commands, timers and recording state logic are unchanged; only duplicate/premature toast assignments were removed.
- Swift syntax and whitespace checks passed for the current worktree.
- Xcode check run 44292279472 succeeded: compile/decode the exact OTA model declarations; exercise the production coordinator and comparator with account/radio substitutes; typecheck the production dialog; run existing HomeVideoCaptureTests.
- Cases include numeric/string/Boolean/missing force flags, English content and Chinese fallback, absent notes, empty URL, placeholder/equal/older/newer versions, another device's package, disconnect and logout.
- This is component compilation and regression testing, not a full new IPA build or physical-glasses verification. Build remains 179.
