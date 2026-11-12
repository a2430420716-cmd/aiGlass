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
  BLE reconnect suspended. Before starting the transport, wait 2.5 seconds after
  releasing the normal connection, matching the latest Android handoff delay.
  Log elapsed time and passive audio-route snapshots before and after that wait.
  Android additionally requests A2DP/HFP disconnection through Android profile APIs;
  iOS has no public equivalent for disconnecting a system Bluetooth audio device.
  AudioSession deactivation or changing the output route would not prove that the
  classic link has disconnected. Keep this platform limitation explicit when
  diagnosing native BLE timeouts; the longer delay/retries are not hardware proof.
  Keep the firmware and SDK state through the loader's
  reconnect. After authentication and feature discovery, continue with
  `cmdOtaDataIIResult` so the device can pull firmware in the second stage.
  Neither loader completion nor its reboot completes OTA. The UI shows both
  stages and the intervening reconnect separately.
- Initial AE00 service acquisition and the loader reconnect each use a fixed
  90-second total deadline. Ignore explicitly nonconnectable advertisements.
  Allow at most three native connection attempts,
  with at most 25 seconds each through authentication and feature discovery. Release
  a stalled attempt before scanning again for the exact UUID (or the SDK-provided
  loader MAC). Retrieve the cached UUID only on the first attempt; retries wait for
  a fresh matching advertisement. After an attempt times out, replace only the OTA
  central after releasing the link, even when cancellation returns normally. A
  successful cancellation callback does not establish that this central can acquire
  the rebooted loader. If cancellation produces no callback within three seconds,
  use the same replacement path. Retain the SDK, image, attempt count and original
  deadline. Do not create another central after the final attempt or deadline.
  SDK disconnect notifications during acquisition cannot shorten its total budget.
  Obsolete central callbacks and callbacks during release cannot resume the image.
  A recovered initial connection submits `cmdOTAData` once; a loader reconnect uses
  `cmdOtaDataIIResult`, never restarting the loader or reporting success from the
  first transfer. A pre-submission timeout still does not create recovery evidence:
  no firmware has been submitted, so Android also excludes it from forced recovery.
  Ordinary standby reconnect and Gen2
  updates do not use this retry policy.
- Clear recovery evidence only after a fresh matching normal-service version
  from the same device and owning account. SDK terminal success, 100%, and reboot
  retain the marker while the UI waits at 95% for version confirmation. After app
  restart, a fresh matching Bluetooth-version reply also clears the marker and
  withdraws the recovery reminder. Old/missing versions retain recovery evidence.
  This intentionally differs from Android's optimistic success on cancellation
  after a complete transfer.
- Logs record reminder, target, session, image submission, retained failures
  and marker clearance. Loader matching also records the SDK's expected MAC,
  matching peripheral name/UUID, advertised services and at most 64 manufacturer
  bytes, so device-side connection failures can be correlated with the OTA broadcast.
  The native connecting state alone cannot establish the physical cause of a timeout.
  Record no new Wi-Fi credentials or authorization tokens.

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
