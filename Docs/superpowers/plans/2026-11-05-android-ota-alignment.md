# Android OTA Alignment Implementation Plan

> **For agentic workers:** Execute natively in the authorized session. No delegation or execution subskill is available or needed.

**Goal:** Synchronize applicable OTA improvements from the November 5 Android source package while preserving iOS recovery evidence and Gen2 OTA behavior.

**Architecture:** Keep RCSP transfer and recovery unchanged; extend only its initial handoff delay and diagnostics. Add an explicit main-firmware session phase between provisioning success and sending `0x09`, with confirm/cancel actions exposed through the manager and the existing detail page.

**Tech Stack:** Swift 6, SwiftUI native alert, Foundation session tests, CoreBluetooth, Jieli RCSP.

**Spec:** User-supplied `glasses(1).zip`; source extracted to sibling `analysis/android-ota-20261105-latest`. Changed files: `Gen1BluetoothOtaManager.java`, `OtaUpgradeManager.java`, `FirmwareUpdateDetailActivity.kt`; unchanged `Gen1OtaFailureStore.kt`, forced-upgrade entry and vendor AARs.

## Global Constraints

- Confirmed Gen1 OTA paths only; Gen2 OTA remains unchanged.
- Keep 1.1.6 (171), existing in-progress BLE fixes and charging correction; no packaging requested.
- No generation labels added to app copy/logs; never log Wi-Fi credentials.
- iOS cannot disconnect system A2DP/HFP devices using public APIs. Route changes and AudioSession deactivation do not establish physical disconnection.
- Keep the existing 30-second Wi-Fi response wait; Android increased 10 to 15 seconds.
- No pre-submission connection failure creates or clears interrupted-flash evidence.

## Review Focus

- Successful Wi-Fi reply alone must not send the firmware start command.
- Waiting for a person must not consume the 30-second firmware startup timeout.
- Cancellation while awaiting confirmation must release the owned busy state without starting OTA.
- Late/duplicate confirmations and late provisioning/progress frames must not start twice or finish early.
- Account/device changes or loss of BLE before confirmation must prevent further commands.

## Task 1: Explicit provisioning confirmation

**Files:** `AIGlass/Gen1FirmwareUpdateSession.swift`, `AIGlass/BluetoothOtaUpgradeManager.swift`, `AIGlass/DeviceOtaUpgradeDetailView.swift`, `Tests/Gen1FirmwareUpdateSessionTests.swift`.

**Interfaces:** New phase `.awaitingWifiConfirmation`; session `confirmWifiProvision()` / `cancelWifiProvision()` accept the first decision only while running in that phase. Manager `isAwaitingGen1WifiConfirmation`, `confirmGen1WifiProvision()` / `cancelGen1WifiProvision()` expose the active owned session. Waiting polls cancellation, connection and account/binding validity; declining throws `.wifiConfirmationCancelled` before `0x09` and returns the manager to idle. Actual task cancellation retains its existing error path.

- [x] Add tests with injected time: wait 45 seconds before confirmation, verify only battery/provision commands; then start once and keep the full startup timeout. Test user cancel, duplicate/early decisions, connection loss, target change, and task cancellation while awaiting confirmation.
- [x] Insert waiting phase, one-shot decisions and pre-start validation; wire manager actions and cleanup.
- [x] Show native “Wi-Fi 配网成功” alert with “取消” / “下一步”; cancel if the owned detail page disappears during the wait. Keep native accessibility and localized copy.
- [x] Attempt firmware-session regressions: local run stops at `xcrun: command not found`. Windows Swift syntax and diff checks pass. Runtime/Xcode/UI/hardware validation remains pending.

## Task 2: Bluetooth handoff and comparison record

**Files:** `AIGlass/BluetoothOtaUpgradeManager.swift`, `Docs/Gen1-Bluetooth-OTA-Recovery.md`, `Docs/Gen1-Firmware-OTA.md`; sibling analysis comparison report.

**Interfaces:** Gen1 Bluetooth manager waits 2,500 ms after releasing normal BLE before creating RCSP transport; logs passive audio-route snapshots before and after. This is not A2DP/HFP disconnection.

- [x] Synchronize 800 → 2,500 ms handoff delay, recheck cancellation/binding, and log elapsed/route evidence.
- [x] Document unchanged force-recovery rules/vendor SDKs, the public-iOS API limitation, and unrelated Android connection/query changes that do not alter Gen2 OTA.
- [x] Check complete diff, source syntax, fixed version/build and preservation of prior edits.
