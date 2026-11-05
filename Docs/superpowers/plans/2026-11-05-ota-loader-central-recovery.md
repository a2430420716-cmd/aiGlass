# OTA Loader Connection Recovery Implementation Plan

> **For agentic workers:** Execute natively under the user's existing bug-fix request. Keep the pending Bluetooth permission timing changes intact.

**Goal:** Recover a timed-out loader connection with a fresh OTA central even when cancellation returns normally, and record enough identity evidence for device-side diagnosis.

**Architecture:** Extend the existing bounded connection policy with a release decision that requires central replacement after a timeout. Route both normal release callbacks and the existing three-second release timeout through that decision. Preserve the SDK, firmware, original recovery record, exact vendor MAC match, attempt limit and absolute deadline.

**Tech Stack:** Swift, CoreBluetooth, Jieli RCSP; existing Foundation-only OTA stage regression executable.

**Spec:** Nov 5 build 172 logs, extracted under `../analysis/ota-20261105-2008/` relative to the repository root. At 19:55 and 20:03 the loader transfers finish, then the same matching loader UUID remains connecting through three 25-second attempts. Cancellation callbacks arrive immediately, so the current missing-callback-only central replacement never runs. At 19:49 an earlier session completes and reads back version 03.26.02.19. This proves the failure stage, not the physical radio cause.

## Global Constraints

- Gen1 Bluetooth OTA only; preserve Gen2, main firmware and normal BLE reconnection.
- Keep version 1.1.6. Initial implementation retained build 172; the subsequent user packaging request increments it to 173.
- Preserve three attempts, 25-second attempt and 90-second total limits.
- Require the original UUID or SDK-provided loader MAC; never broaden to nearby devices by name.
- Keep interrupted-flash evidence on failure; never report success without stage completion/version verification.
- No private APIs or claim that rebuilding a central disconnects system audio or proves hardware recovery.

## Review Focus

- Cancellation callback arrives after a native timeout: replacement still happens before retry.
- No release callback: existing three-second fallback remains bounded and replaces once.
- Delayed old callbacks/timers: cannot affect the new central or restart the image.
- Final attempt/expired deadline/cancel: no new central or extra retry.
- Loader reconnect after replacement: resume stage two with the retained image and SDK.

## Task 1: Release policy and transport integration

**Files:** `AIGlass/Gen1BluetoothOtaSessionState.swift`, `AIGlass/Gen1BluetoothOtaTransport.swift`, `Tests/Gen1BluetoothOtaSessionStateTests.swift`.

**Interfaces:** `retryActionAfterRelease(now:releaseTimedOut:)` returns scan, replace-central or no remaining work. `centralDidReplace()` consumes the replacement requirement without resetting deadline or attempt count.

- [x] Add regressions for the two observed timeout/release sequences, cancellation, stale expiry, normal disconnect and no-callback fallback.
- [x] Require replacement after native timeout; reuse one replacement routine from callback and fallback paths.
- [x] Keep MAC-only loader discovery and log matching target name, expected MAC, advertised service UUIDs and bounded manufacturer bytes.
- [x] Review stage continuity and original recovery identity; retain test/build version.

## Task 2: Evidence and verification

**Files:** `Docs/Gen1-Bluetooth-OTA-Recovery.md`; external `analysis/ota-20261105-2008/findings.md`.

- [x] Record the successful session, two loader failures, retry behavior and recovery prompt timestamps.
- [x] Run available Swift syntax/source checks and shell/diff checks.
- [ ] Execute the Swift regression executable and Xcode build on macOS; retest loader recovery with physical glasses.
- [x] Report the exact failure stage, implemented recovery change and remaining hardware verification.

## Verification record

Tree-sitter parsed both changed Swift sources and the regression source without syntax errors. Source assertions preserve the two acquisition budgets, vendor MAC matching, second-stage resume command and SDK/image/recovery state during central replacement. No diff in the Gen2 OTA manager, main firmware session or project version settings. Bash syntax and `git diff --check` passed.

Attempting `Tests/run-gen1-bluetooth-ota-tests.sh` on this Windows host exited at line 7: `xcrun: command not found`. Therefore the new Swift regressions have not executed, and no Xcode build or physical-device pass is claimed. No package was generated; version remains 1.1.6 (172). Pending Bluetooth authorization timing edits remain intact.

## Packaging follow-up

The user subsequently requested packaging with build +1. Increment Debug and Release to 173, include both the loader recovery and pending Bluetooth authorization timing changes, run the existing macOS regression/build workflow, and verify the exported development IPA before delivery. Physical-device loader recovery remains a separate retest.
