# Gen1 Bluetooth OTA recovery

Aligned with `glasses(3).zip`: Android `Gen1OtaFailureStore`,
`Gen1BluetoothOtaManager`, `MainActivity.checkGen1ForcedUpgrade` and
`FirmwareUpdateDetailActivity.forcedUpgrade`.

- Only Gen1 G5K61 Bluetooth OTA uses this path. Gen1 main firmware and Gen2
  updates retain their existing flows.
- Persist target peripheral UUID and package metadata immediately before
  `cmdOTAData`. App termination or an interrupted transfer leaves recovery
  evidence. A connection/authentication/download failure before submission
  does not create a marker or erase an older interrupted update.
- After the same bound device reconnects, show a bilingual recovery reminder.
  “Later” suppresses repeats for this connection; reconnecting reminds again.
  The ordinary upgrade page also exposes the recovery offer.
- Recovery offers precede fresh-version guards and permit the same version.
  Select the server package matched to this device's SN/UUID; if unavailable,
  reuse only this UUID's recorded package metadata. Never use another device's
  package or infer recovery solely from a version-read timeout.
- Keep existing bound-device, generation, idle/import exclusion and battery
  gates (Gen1 at least 80%). Only the fresh-version-read requirement is waived.
- Submit through the existing AE00/AE01/AE02 Jieli RCSP transport, with normal
  BLE reconnect suspended. Keep the firmware and SDK state through the loader's
  reconnect. After authentication and feature discovery, continue with
  `cmdOtaDataIIResult` so the device can pull firmware in the second stage.
  Neither loader completion nor its reboot completes OTA. The UI shows both
  stages and the intervening reconnect separately.
- During the loader reconnect, ignore explicitly nonconnectable advertisements.
  Keep the 90-second total deadline; allow at most three native connection attempts,
  with at most 25 seconds each through authentication and feature discovery. Release
  a stalled attempt before scanning again. If cancellation produces no callback
  within three seconds, replace only the OTA central, retaining the SDK and image.
  Obsolete central callbacks and callbacks during release cannot resume the image.
  A recovered connection still uses `cmdOtaDataIIResult`; it never restarts the loader
  or reports success from the first transfer. Ordinary standby reconnect and Gen2
  updates do not use this retry policy.
- Clear recovery evidence only on SDK terminal success or a fresh matching
  version after the second transfer's reboot; 100% alone does not clear it. Normal-service fresh
  version verification still decides whether the UI confirms success or shows
  an unconfirmed result. This intentionally differs from Android's optimistic
  success on cancellation after a complete transfer.
- Logs record reminder, target, session, image submission, retained failures
  and marker clearance. Record no new Wi-Fi credentials or authorization tokens.

Validation: persistence/device-isolation tests in
`Tests/Gen1BluetoothOtaRecoveryTests.swift` and two-stage transition tests in
`Tests/Gen1BluetoothOtaSessionStateTests.swift`, included in
`Tests/run-gen1-tests.sh`. Windows source validation cannot replace an Xcode
build or hardware checks. Verify interruption during transfer, app restart,
failed authentication during recovery, two-device switching, missing version
replies, low/unknown battery and normal completion on hardware.

This is recovery for a device that can reconnect through its normal BLE service,
matching Android's entry condition. Bootloader-only advertising without the
normal service requires a separate discovery/identity workflow.
