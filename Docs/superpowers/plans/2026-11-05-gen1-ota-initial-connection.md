# Gen1 OTA Initial Connection Recovery Implementation Plan

> **For agentic workers:** Execute natively in this session. The referenced superpowers execution skills are unavailable; repository instructions and the authorized bug fix govern execution.

**Goal:** Recover a stalled initial RCSP connection without confusing it with an interrupted firmware transfer.

**Architecture:** Use the bounded connection policy for both initial service acquisition and the SDK-requested loader reconnect. Retry a released connection through matching advertisements, keeping SDK stage transitions and persisted recovery evidence independent from connection attempts.

**Tech Stack:** Swift 6, CoreBluetooth, Jieli RCSP, Foundation-only regression executables.

**Spec:** User report dated 2026-11-05; evidence in `../../../../analysis/gen1-bluetooth-ota-20261105-1022/findings.md`. The sole session waits from 10:21:29.278 to 10:22:09.272 without `didConnect` or image submission. Android also excludes pre-transfer failures from forced recovery.

## Global Constraints

- Scope: Gen1 Bluetooth OTA only; preserve Gen2 and normal standby reconnect.
- Preserve version 1.1.6 and build 171; no packaging requested.
- No generation labels added to app copy or logs.
- Never manufacture or erase interrupted-flash evidence on a pre-submission failure.
- Windows validation cannot establish an Xcode build or hardware success.

## Review Focus

- Initial native connect remains pending: bounded release, exact-target rescan and retry.
- Cancellation has no callback: replace only the OTA central after three seconds.
- Duplicate advertisements or old timers: no parallel attempts or changed total deadline.
- SDK disconnect notification before image submission: retain the initial connection deadline.
- Retried initial connection versus loader reconnect: issue `.start` versus `.resume` exactly once.

## Task 1: Extend bounded connection acquisition

**Files:** Modify `AIGlass/Gen1BluetoothOtaSessionState.swift`, `AIGlass/Gen1BluetoothOtaTransport.swift`; test `Tests/Gen1BluetoothOtaSessionStateTests.swift`.

**Interfaces:** `Gen1BluetoothOtaConnectionPolicy` exposes `isActive`, `shouldRetrieveCachedPeripheral`, and the existing `begin(now:)`, `claim`, `expire`, `stop` operations. Initial acquisition and loader reconnect each receive 90 seconds total, 25 seconds per attempt through feature discovery, at most three attempts. `reconnectRequested` continues to mean SDK loader reconnect only.

- [x] Add regressions for the Nov 5 initial stall: first attempt expires at 25; retry requires an advertisement; initial feature result still yields `.start`; loader retry still yields `.resume`.
- [x] Implement initial policy activation, shared timeout/release/retry handling and UUID-only initial rediscovery. Do not let SDK disconnect replace an active connection budget with the transfer-interruption timeout.
- [x] Check stale attempt, stop, retry exhaustion, nonconnectable advertisements and unchanged absolute deadlines. Keep the existing three-second central replacement safeguard.
- [x] Perform Windows Swift syntax parsing and source review. Swift runtime execution, `bash Tests/run-gen1-bluetooth-ota-tests.sh` on macOS and hardware verification remain pending; no local toolchain is available.

## Task 2: Document recovery boundary and verification

**Files:** Modify `Docs/Gen1-Bluetooth-OTA-Recovery.md`; preserve `AIGlass/Gen1BluetoothOtaRecoveryStore.swift` and reminder semantics.

**Interfaces:** Persist only before `cmdOTAData`/resume; connection acquisition neither creates a new marker nor deletes an older device-scoped marker.

- [x] Review existing persistence tests and reminder eligibility against Android's pre-transfer failure behavior.
- [x] Document initial acquisition retries and the distinction between pre-write connection failure and interrupted flashing.
- [x] Run `git diff --check`, inspect the complete diff and report local verification limits. Leave changes reviewable without a build or version increment.
