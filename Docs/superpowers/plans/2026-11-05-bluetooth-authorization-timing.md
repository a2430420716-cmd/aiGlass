# Bluetooth Authorization Timing Implementation Plan

> **For agentic workers:** Execute natively in this session under the user's authorized fix. Preserve existing device connection ownership and recovery behavior.

**Goal:** Request initial Bluetooth permission only when the user starts pairing or explicitly taps a bound device's connect button.

**Architecture:** Gate creation of the existing CoreBluetooth central on authorization and the initiating action. Automatic startup, home selection, refresh and binding adoption may initialize an already authorized central, but must never initiate the first permission request. Keep the original central restoration identifier and powered-on continuation paths.

**Tech Stack:** Swift, SwiftUI, CoreBluetooth; Foundation-only policy regression executable.

**Spec:** User request dated 2026-11-05: delay initial Bluetooth authorization; provide the domestic review-account login request separately.

## Global Constraints

- Keep version 1.1.6. Initial implementation retained build 172; the subsequent user packaging request increments it to 173. No account changes or App Store submission requested.
- Preserve automatic reconnection for users who have granted Bluetooth permission.
- Denied/restricted authorization must not be requested repeatedly; explicit actions show the existing Settings guidance.
- Login and server selection must work without creating a central or granting Bluetooth permission.
- Keep domestic and overseas authentication routing unchanged.

## Review Focus

- Fresh install: startup, login, home refresh and automatic card selection never trigger permission.
- Explicit pairing/connect: create the central once, then continue when powered on.
- Permission denied or restricted: no crash from an uninitialized central, clear Settings guidance on explicit action.
- Pairing canceled or logout while permission is pending: no delayed scan or reconnect.
- Existing authorization: preserve state restoration, exact-device selection and OTA reconnection.

## Task 1: Gate Bluetooth initialization and protect inactive entry points

**Files:** `AIGlass/Bluetooth/AstraA1/BluetoothActivationPolicy.swift`, `AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift`, `AIGlass/HomeView.swift`.

**Interfaces:** A Foundation-only policy decides whether an automatic or explicit connection action may initialize Bluetooth. The manager central remains uninitialized until permitted. Only `startPairing` and the explicit home connect action can authorize a first request; refresh paths remain automatic.

- [x] Add policy regressions for fresh, authorized, denied and restricted states and repeated automatic refreshes. The fake central factory verifies zero creations during passive use and exactly one after an explicit action.
- [x] Apply the gate before central creation; retain the restoration identifier and delegate continuations.
- [x] Guard passive adoption, selection, refresh, cleanup and diagnostics against an absent central. Preserve pending device identity until authorization completes; cancel pairing/logout pending work.
- [x] Review all central access paths and initial powered-on behavior. `startPairing` clears stale adoption/battery work; cancel/logout clears queued adoption and pairing requests.

## Task 2: Verify and provide domestic request details

**Files:** `Tests/BluetoothActivationPolicyTests.swift`, `Tests/run-gatt-recovery-tests.sh`; external analysis output only for HTTP request evidence.

- [x] Include the policy regression executable in the existing BLE CI check.
- [x] Run available syntax, source integration and diff checks; report lack of local Xcode/Swift honestly. Swift syntax parsing passed for new policy/tests, HomeView and 17 affected BLE-manager method fragments; shell syntax and `git diff --check` passed. Swift execution, Xcode build and device permission checks remain pending on macOS/iOS.
- [x] Recheck the domestic endpoint with the provided demo credentials; return URL, method, relevant headers, JSON body and response without changing the account. HTTP 200, business code -1, `result: null`, message `账户不存在`.

## Device verification remaining

1. Fresh install: open app, select server, sign in, browse/refresh home; no Bluetooth alert.
2. Tap Start Pairing with a selected model: one permission alert; Allow continues scanning; Deny displays existing Bluetooth Settings guidance.
3. Fresh install with an account-bound device: automatic card selection/refresh has no alert; tapping Connect requests permission and resumes the exact selected device.
4. Cancel pairing or log out while authorization is unresolved; granting permission afterward must not resume the canceled scan or adopt an old binding.
5. Relaunch with permission already allowed and a bound device: automatic restoration and foreground reconnect continue working.
