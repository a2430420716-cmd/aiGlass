# OTA Retry Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce avoidable Gen1 BLE reconnect waiting, preserve a recoverable BLE loader identity after interruption, and support bounded Gen2 hotspot retry with manual connection fallback.

**Architecture:** Gen1 OTA stays on CoreBluetooth BLE RCSP. Persist the original image hash, account and OTA identity so the same bound device can be recovered without its normal control service. Gen2 keeps BLE hotspot control and Wi-Fi transfer; a separate preparation session owns two automatic joins and a bounded manual connection step before upload.

**Tech Stack:** Swift, SwiftUI, CoreBluetooth, NetworkExtension, existing lightweight Swift test harnesses.

**Spec:** User request to optimize Gen1 BLE upgrade and Gen2 hotspot upgrade failures.

## Global Constraints

- Gen1 OTA uses BLE RCSP AE00/AE01/AE02; no Classic Bluetooth API or audio route manipulation.
- Gen2 still uses BLE to open the hotspot, then Wi-Fi for file transfer.
- OTA success remains gated by SDK completion and post-upgrade version verification.
- Keep current marketing/build version unchanged.
- Existing phone masking and voice-status background edits must remain intact.

## Review Focus

- Gen1 attempt budget exhausted: fail immediately instead of waiting for an already impossible total deadline.
- Gen2 transient hotspot association/IP timeout: one fresh BLE hotspot configuration and Wi-Fi join retry.
- User denial or non-transient join errors: do not silently repeat.
- Retry must not bypass existing cleanup, cancellation, or version verification.
- Account/binding changes during BLE recovery or manual Wi-Fi waiting stop the owned session.
- A restored normal BLE connection must pass its ordinary idle and battery checks.
- Legacy recovery records remain decodable but cannot authorize direct loader recovery without identity, account and hash metadata.

### Task 1: Gen1 BLE reconnect exhaustion

**Files:**
- Modify: `AIGlass/Gen1BluetoothOtaTransport.swift`
- Modify: `AIGlass/Gen1BluetoothOtaRecoveryStore.swift`
- Modify: `AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift`
- Modify: `AIGlass/BluetoothOtaUpgradeManager.swift`
- Modify: `AIGlass/DeviceFirmwareUpdateCoordinator.swift`, `AIGlass/MainTabView.swift`, `AIGlass/GlassesFirmwareUpgradeView.swift`, `AIGlass/DeviceOtaUpgradeDetailView.swift`
- Test: `Tests/Gen1BluetoothOtaRecoveryTests.swift`

- [x] Finish immediately when the three bounded connection attempts are exhausted; keep 25-second attempts and the 90-second overall bound.
- [x] Preserve same-session SDK/image state and use the existing second-stage resume command.
- [x] Save account, SHA-256, OTA MAC and discovered OTA UUID alongside submitted-image evidence; never match by device name.
- [x] Add explicit recovery entry for the same bound device, using the recorded package and requiring SDK forced-OTA mode before direct loader submission.
- [x] Check ownership throughout transfer; enforce normal idle/battery gates if the control connection returns before recovery begins.
- [x] Let a validated offline recovery record own the existing firmware-flow busy state, background-query suppression and normal BLE restoration/version verification.
- [x] Extend persistence tests for same target/account authorization and legacy JSON decoding.

### Task 2: Gen2 hotspot join retry

**Files:**
- Modify: `AIGlass/BluetoothOtaUpgradeManager.swift`
- Modify: `AIGlass/Album/DeviceWifiManager.swift`
- Modify: `AIGlass/DeviceOtaUpgradeDetailView.swift`
- Create: `AIGlass/Gen2OtaWifiConnectionSession.swift`
- Test: `Tests/Gen2OtaWifiConnectionSessionTests.swift`

- [x] Limit automatic preparation to two attempts; close/reopen the device hotspot and fetch fresh BLE credentials before the second attempt.
- [x] Retry only `DeviceWifiError.unreachable`; keep user denial and other system errors terminal.
- [x] Bound the OTA system apply callback wait to 45 seconds, retaining the existing 30-second SSID/IP readiness window.
- [x] Wait three seconds after removing an OTA hotspot configuration before applying it again.
- [x] After two association/IP failures, retain the final hotspot for a 180-second manual connection decision; show SSID/password and Continue/Cancel controls.
- [x] Verify manually joined SSID/IP without reapplying configuration, then continue the existing HTTP and upgrade flow.
- [x] Stop on account/target change, handle cancellation and late taps once, and keep cleanup in the OTA owner.
- [x] Add tests covering automatic success, retry order/fresh credentials, denial, manual verification, repeated checks, cancellation, target changes and deadline.

### Task 3: Verification

**Files:**
- Existing tests: `Tests/run-gen1-bluetooth-ota-tests.sh`, `Tests/run-gen2-ota-recovery-tests.sh`
- Create: `Tests/run-gen2-ota-wifi-session-tests.sh`
- Modify: `.github/workflows/ios-ipa.yml`

- [x] Parse changed Swift syntax against HEAD, run `git diff --check`, shell syntax and workflow YAML checks locally. Existing Swift grammar limitations in `DeviceWifiManager` are unchanged.
- [x] Integrate new session tests into the existing Mac build checks.
- [ ] Run Swift tests and Xcode compilation on a Mac. Local invocation stops at `xcrun: command not found` on Windows; runtime tests have not passed here.
- [ ] Verify Gen1 BLE upgrade/recovery and Gen2 automatic/manual hotspot flows on physical devices; native connection/AP root causes remain unconfirmed.
- [x] Confirm build settings remain `CURRENT_PROJECT_VERSION = 174` and `MARKETING_VERSION = 1.1.6`.

## Packaging follow-up

The user subsequently requested a package with build +1. The packaging revision is `1.1.6 (175)` and includes the completed OTA optimization, existing phone masking changes and removal of the voice-status white background. Mac checks and signed archive/export run through the existing `ios-ipa.yml` workflow using the established development profile.
