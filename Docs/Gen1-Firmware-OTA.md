# Gen1 main-firmware OTA

Updated 2026-09-29 against Android `OtaUpgradeManager.java`, `Gen1Payloads`, and `FirmwareUpdateDetailActivity.kt`.

2026-09-30: iOS waits 30 seconds for each `0x06` provisioning reply before a timeout retry, allowing slow router connections to finish. The November 5 Android package increased its timeout from 10 to 15 seconds; iOS retains its longer wait.

2026-11-05: A successful provisioning reply now opens an explicit confirmation step,
matching the latest Android flow. No firmware URL is sent until the user chooses Next.

## Flow

This branch runs only for confirmed Gen1 G5K61/L1 main-firmware updates. It does not use the album AP commands (`0x37`/`0x38`), TCP 8556, Gen2 HTTP upload, or Jieli Bluetooth OTA.

1. The detail page collects a router SSID and password. The app requires a nonblank password; UTF-8 SSIDs are supported. Trim the SSID, preserve password bytes, and enforce Android's 127-byte per-field limit.
   Since 2026-10-14, opening this form requests when-in-use location authorization
   (temporary precise authorization when required) and uses `NEHotspotNetwork.fetchCurrent`
   to prefill an untouched, empty SSID field. No location samples are requested.
   Denial, an unavailable SSID or a read timeout leaves manual entry usable. Editing
   the SSID, leaving the form or starting OTA invalidates pending callbacks. Passwords
   remain manual; the existing 2.4 GHz requirement remains visible. Other OTA pages
   do not request location authorization. Permission decisions and read outcomes are
   recorded in Wi-Fi debug logs without the SSID or password contents.
2. Claim the current account and bound peripheral, excluding capture, recording, AP import and another OTA. A logout authorization epoch prevents a logout/login cycle from resuming an old update.
3. Query battery with empty `0x05`, waiting up to 3 seconds. Match Android's `max(fresh reading, pre-query cached reading)`; ignore values outside 0...100. Require at least 80%. A timeout may use valid cached battery; unknown battery fails rather than bypassing the gate.
4. Send `0x06` with UTF-8 `SSID/password`. Wait up to 30 seconds per attempt; two attempts maximum. Empty replies do not finish the wait. Only reply byte `0x01` succeeds; a non-success reply can trigger the second attempt immediately. A failed send ends provisioning immediately. Logs record the active timeout. Final failure queries empty `0x17` for up to 3 seconds of diagnostics and never sends `0x09`.
5. Enter `awaitingWifiConfirmation` after successful provisioning. Show Cancel / Next. Cancel releases the owned upgrade claim and returns to idle without sending `0x09`; Next authorizes it once. Waiting for the user does not consume the firmware-start timeout. During the wait, connection loss, account/device changes or task cancellation stop the flow; late provisioning/progress frames cannot bypass this step. Then send `0x09` with `[0x01] + URL bytes`, without a NUL terminator. Convert HTTPS to HTTP only for the configured API server's exact host, matching Android's own-server rule. Other HTTPS URLs, URL credentials/fragments, spaces and non-ASCII bytes are rejected. No app authorization header is forwarded to the glasses.
6. Successful startup has no ACK. Wait 30 seconds for first progress; then allow 180 seconds between valid progress frames. Accept current `0x3A` and legacy `0x18`, 0...100 only; never clamp malformed values to success. `0x09` failure/busy replies stop the flow.
7. At 100%, send empty `0x12` to restart. If BLE was interrupted, wait for the same target before sending. A failed restart command is not success.
8. After the reboot delay, reconnect the original target and query `0x15` every 3 seconds, up to 90 seconds. Only a fresh matching version completes the update. Unlike Android's fixed 60-second success delay, iOS retains its existing version confirmation.

Every wait rechecks account, binding, generation and peripheral identity. Late phase replies cannot advance a different phase. Business commands are blocked during the claimed main-firmware flow. Cleanup releases its own claim and does not reset a replacement device's runtime status. Wi-Fi credentials are not persisted; outgoing credential packets, including BLE fragments, are redacted in debug logs.

## Validation

Protocol vectors and boundaries: `Tests/Gen1FirmwareUpdateTests.swift`.

Injected-clock, scripted-device flow tests: `Tests/Gen1FirmwareUpdateSessionTests.swift`; run with `bash Tests/run-gen1-firmware-session-tests.sh`. Included in `bash Tests/run-gen1-tests.sh`.

Shared Bluetooth/Gen2 regression: `bash Tests/run-bluetooth-regression-tests.sh`.

2026-09-29 results: 564 protocol assertions, 135 OTA session assertions; 1,339 assertions in the full Gen1 suite and 1,289 in the shared Bluetooth/Gen2 suite passed. Full unsigned Debug build for `generic/platform=iOS` passed. Gen2 OTA/recovery method bodies are unchanged against the pre-task source snapshot.

Hardware checks still required:

- Gen1 ≥80%, normal and Chinese SSIDs, password-protected 2.4 GHz routers; blank-password validation on the detail page.
- Successful provisioning held longer than 30 seconds before Next; Cancel; connection/account/device changes while the confirmation is open.
- Wrong password, unreachable router and unavailable firmware URL; provisioning must fail without starting OTA.
- Current `0x3A` and older `0x18` firmware progress, including slow periods between progress frames.
- Reboot, temporary BLE loss and fresh version match/mismatch; never report success from upload progress alone.
- Logout, unbind and device switch during battery query, provisioning, download and version verification.
- Gen1 Bluetooth OTA and Gen2 firmware/Bluetooth OTA smoke tests on hardware.
