# Record Duration Verification Implementation Plan

**Goal:** Confirm the Gen1 recording limit from a device query instead of treating a queued write or an ambiguous SET acknowledgement as success.

**Architecture:** A small state value distinguishes SET replies from QUERY replies and owns a bounded verification token. The BLE manager reads back after a SET, retries the query once, and cancels verification when the connection changes. Settings persist only device-reported values for Gen1. Gen2 behavior stays unchanged.

**Tech Stack:** Swift, SwiftUI, CoreBluetooth, existing standalone Swift tests.

**Spec:** The November 10 recording trace sets profile 3 (300 seconds), starts recording, receives device standby 12.54 seconds later without an App STOP, then repeatedly receives empty media lists. The trace does not establish whether firmware applied the requested limit or why it did not advertise a file.

## Constraints and review focus

- Do not change recording START/STOP ownership or synthesize a five-minute recording.
- Do not interpret 0x25 payload zero as the 15-second profile.
- Only a valid 0x87 QUERY after verification begins can confirm the requested duration.
- Mismatch, invalid response and silence must never produce a success alert.
- Connection reset and superseded requests invalidate delayed queries and results.
- Keep version 1.1.6 (175); no packaging requested for this investigation.

## Task 1: Verify and expose actual duration

Files: `AIGlass/Bluetooth/Gen1/Gen1RecordDurationSettingState.swift`, `AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift`, `AIGlass/GlassesSettingsView.swift`, `Tests/Gen1RecordDurationSettingTests.swift`, `Tests/run-gen1-record-duration-tests.sh`, `Tests/run-gen1-tests.sh`.

- [x] Add regression cases for SET ACK zero, matching QUERY profile 3, mismatched QUERY, missing/invalid replies, repeated same-value changes and reset/superseded tokens.
- [x] Separate SET acknowledgements from actual setting values; record command/profile diagnostics.
- [x] Query after 1 second and retry after 3 seconds; finish unconfirmed/mismatch after 6 seconds. Never resend SET automatically. Send only to the same ready, idle Gen1 connection and skip setting-page queries during verification.
- [x] Show Gen1 setting success only on matching device readback; preserve prior value until readback, and show actual value or an unconfirmed warning on failure.
- [x] Add tests to existing Mac protocol suite; run locally available syntax/diff checks. Report inability to run Swift/Xcode on Windows honestly.

## Task 2: Evidence and validation

- [x] Save a timeline with original log line references and separate confirmed facts from hypotheses.
- [x] User confirms the reported failure happened while wearing the glasses, with wear detection enabled. Do not attribute it to intentional removal.
- [ ] Compare five-minute recording while worn with wear detection disabled, then hardware-button recording. Still needs physical glasses.
- [ ] Obtain the same-attempt device log if early stop/no-file persists; App-only logs cannot identify the camera/storage/firmware stop reason.
