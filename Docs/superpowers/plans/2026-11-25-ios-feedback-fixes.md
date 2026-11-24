# iOS feedback fixes implementation plan

> Execute sequentially in this session. Preserve the user's existing home disconnected-feedback changes.

**Goal:** Correct the reported copy, login navigation, home icon sizing, simultaneous-record sharing and misleading local video recovery feedback.

**Architecture:** Reuse existing SwiftUI navigation, record storage and system sharing. Keep completed Gen1 originals immutable; persist processing failures with their existing account/device-scoped inbox entry. Validate readable video metadata before enhancement and show actionable errors without claiming a damaged video can be repaired.

**Tech Stack:** SwiftUI (iOS 15+), AVFoundation, UIKit, Codable inbox metadata.

**Spec:** User reports and screenshots in this chat, plus Android `glasses(2).zip` resources and `TranslationRecordListActivity.shareSelectedRecords`.

## Constraints

- Wake-up text matches Android exactly: only `Hi MOCO`, no `Hey MOCO`.
- Recording subtitle: `AI transcription summaries, record anytime`.
- Remove `Glasses` only from the firmware dialog's MOCO AI introduction.
- Retain build 181; packaging was not requested in this turn.
- Do not delete unreadable originals or block importing new glasses files.

## Review focus

- Login server selector must sit below the status bar and receive taps on its arrow and text.
- Enlarged home icons must leave single-line English titles readable on narrow phones.
- Sharing must preserve selection order, Unicode, original and translated text; empty selection must prompt.
- Corrupt video, temporary processing failure and Photos permission failure must not be confused with successful import.
- Inbox failure metadata must survive restart and remain isolated by account/device; successful recovery removes only its own inbox entry.

## Tasks

- [x] Confirm Android wake-up copy, restore the exact text, update recording subtitle and firmware introduction.
- [x] Move login background out of foreground layout; place server navigation in a safe-area inset with a 44-point tap target.
- [x] Restore media icons to 64 points (56 on compact cards); match feature icons to Android's 36 points.
- [x] Add record-list selection sharing as plain text using a shared, testable formatter and system share sheet.
- [x] Persist local processing failure reason, preflight Gen1 video tracks/duration/size, and replace guaranteed recovery language with pending/retry copy.
- [x] Check Swift syntax and diffs; run targeted native record-formatting, inbox and media checks when macOS runtime is available. Record limitations honestly.

## Evidence and limits

- Android resource and iOS source both specify only `Hi MOCO`. The screenshot with `Hey MOCO` is not the target wording. No wake-up command or setting behavior changed.
- Android's share button lives in simultaneous translation **record-list selection mode**, not the active recording screen. The implementation follows that behavior and text field order.
- Supplied Wi-Fi log: `2026-11-23-17-40-47.mp4` downloaded fully (2,981,888 bytes) at 17:43:10, then duration reading and enhancement failed; the original fallback also failed. At 17:55 local retry failed again. Another pending file, `2026-01-01-08-00-02-17.mp4`, failed similarly. A complete network transfer is not proof of a finalized camera MP4.
- These logs identify `L1 0361`, hardware SN `G5K612611800361`; the user's report names 0239. Do not claim the log proves the exact sequence for device 0239.
- App changes improve failure classification and recovery wording, preserve original bytes, and retain a separate import-from-glasses action. They do not reconstruct a camera file damaged by interrupted recording.
- Local Swift parsing and `git diff --check` pass. Native run `45435122525` completed targeted tests; unsigned full-app compilation passed (`** BUILD SUCCEEDED **`). Native results: sharing 5 assertions, inbox/AP import 116 assertions, PixSmart profile 30 assertions, video fallback pipeline 31 assertions; unreadable/normal original validation, byte preservation and cancellation also passed.
- No iPhone click test or hardware power-cycle reproduction has been performed in this Windows session. Build remains 181.

- Final compact-screen title scaling was checked separately against the final production card components: run `45436340621`, iOS 15 Swift typecheck passed. All source payload hashes for that final run match the workspace.
