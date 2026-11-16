# Gen2 Indicator Brightness Implementation Plan

> Implementation: execute directly in this session using existing BLE and settings patterns.

**Goal:** Connect the existing Indicator Brightness setting to the Gen2 device's three-level BLE protocol.

**Architecture:** A Foundation-only codec and request state own typed levels, device-confirmed values and one outstanding request. AstraA1BleManager owns sending, bounded retry, connection lifecycle and reply dispatch. GlassesSettingsView reuses its native option dialog and existing alerts.

**Tech Stack:** Swift, Foundation, CoreBluetooth, SwiftUI; iOS 15 compatibility.

**Spec:** D:/xwechat_files/wxid_8zda02e5j9ee22_b546/msg/file/2026-11/指示灯亮度-App对接文档.md (V1.1, 2026-11-11).

## Constraints

- Gen2 only; no new Gen1 command or entry.
- setledbri0: one level byte 0/1/2. getledbri0: empty payload. ledbrirsp0: status + actual level.
- Labels Low/Medium/High; no percentages or assumed initial value.
- One brightness request at a time; failed local sends retry at 250 ms, at most eight attempts. Wait three seconds for a reply after accepting the write.
- On nonzero status apply the returned actual level and show the error. On timeout preserve no unconfirmed selection. Disconnect cancels work and clears per-device state.
- Do not change build number or package the app.

## Review Focus

1. Old firmware never replies: release pending state, make retry available, avoid claiming a setting succeeded.
2. Storage failure returns a different actual level: reflect that level rather than requested value.
3. Device switches while retrying: cancel old work and prevent old task results from touching the new device.
4. Multiple taps/automatic refresh: refuse another brightness request while one is pending.
5. Bad response length/level: reject the frame and let the bounded timeout complete.

## Task 1 — Codec and confirmed request state

Files: create AIGlass/Bluetooth/AstraA1/Gen2IndicatorBrightness.swift, Tests/Gen2IndicatorBrightnessTests.swift, Tests/run-gen2-indicator-brightness-tests.sh.

- [x] Add protocol fixture tests for exact query/set bytes, all levels, malformed responses and nonzero status.
- [x] Implement IndicatorBrightnessLevel, Gen2IndicatorBrightnessProtocol and Gen2IndicatorBrightnessState with no UI/framework dependencies beyond Foundation.
- [x] Cover serialization, acknowledgement-only state changes, device-reported correction, mismatched success, timeout, failed writes, late replies and reset cancellation tokens.
- [x] Add tests to existing macOS build checks. Local Windows environment has no Swift/Xcode; runtime tests remain unexecuted.

## Task 2 — BLE lifecycle

Files: modify AstraA1BleManager.swift, AstraNotificationFramer.swift, DeviceCommandAvailabilityPolicy.swift, DeviceCommandAvailabilityPolicyTests.swift and .github/workflows/ios-ipa.yml.

- [x] Publish the confirmed state and expose queryIndicatorBrightness()/setIndicatorBrightness(level:).
- [x] Serialize requests and retry only failed local sends, with a target/request guard on every continuation.
- [x] Query automatically after Gen2 connection initialization, dispatch ledbrirsp0 and reset on connection loss or device replacement.
- [x] Permit read-only query before binding completes; retain the existing bound-device requirement for setting.
- [x] Requery after a successful factory reset; integrate focused tests into existing CI.

## Task 3 — Existing settings UI

File: modify GlassesSettingsView.swift.

- [x] Show the entry for Gen2 devices, use an unknown/loading/unavailable summary until device confirmation, and open the existing native option dialog.
- [x] Disable duplicate submissions, present request errors, and display the device-returned level even when saving fails.
- [x] Keep existing theme, system dialog accessibility, localization and disconnected settings behavior.
- [x] Review diff, parse changed Swift files and validate test scripts/workflow; record unperformed simulator/device checks.

## Verification

- Passed: changed/new Swift source parsing (tree-sitter-swift), no new diagnostics relative to HEAD; workflow YAML and focused test integration; bash -n; git diff --check.
- Build remains 1.1.6 (177). New Swift file is included by the project's synchronized source group.
- Not run: Swift executable tests, Xcode compilation, simulator UI checks and BLE hardware tests. Windows has no Swift/Xcode or configured WSL distribution.
- Device verification still needed: connect/query, each level and repeat SET, persistence after reboot, device-confirmed errors, old firmware timeout and disconnect/reconnect, factory reset, recording with a lit indicator, and Gen1 exclusion.
- The wire protocol has no transaction identifier; serialization prevents overlapping App requests, but cannot establish the origin of an arbitrarily delayed ACK after a timeout and a subsequent retry.
