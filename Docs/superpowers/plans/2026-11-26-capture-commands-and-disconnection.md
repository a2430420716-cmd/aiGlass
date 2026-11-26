# Capture commands and disconnect state implementation plan

**Goal:** Send photo/start-video commands even at battery <=15%, letting the glasses reject/beep; clear local capture state when the active BLE session is lost.

**Architecture:** Remove the four battery returns in the home entry points and low-level command methods. Keep the app's low-battery notice after successful queue submission. Reuse the existing complete capture reset from connection-state invalidation instead of expiring only unconfirmed starts. Reconnection still queries actual device status.

**Spec:** User explicitly requests command forwarding for the device's low-battery sound and stopping the app's recording state when glasses power off/disconnect.

## Constraints and review focus

- Apply to photo/video for both generations. Other media/OTA battery policies are outside this request.
- Retain connectivity, active-operation and device-target guards. A queued command is not device acceptance.
- Disconnect must cancel capture timers/confirmations, clear start/record/stop flags, and never fabricate a successful saved file or send STOP.
- Preserve stale-callback rejection and account/connection identity checks.
- Local analysis/verification only; no package or version bump. Preserve unrelated detail-page edit.

## Tasks

- [x] Remove early battery returns from `takePhoto`, `startVideo`, `takePhotoFromHome`, `startVideoRecordingFromHome` in `AstraA1BleManager.swift`; retain the notice after command submission.
- [x] Call `resetHomeMediaCaptureState()` in `markDeviceRuntimeStatusUnknown(reason:)` before publishing unknown state. Review idle, Bluetooth unavailable, connecting, failed and disconnected paths.
- [x] Verify changed Swift methods, call-site state transitions, source diff and existing native reset test coverage locally; native compile and power-off behavior await a requested package/device test.

## Android pairing-content reference

Reviewed the user's extracted `glasses(3)` source under `analysis/android-device-names-20261125/glasses/`:

- `PairConfirmActivity.kt:548` reads selected `DeviceInfo.prepare`, then loads HTML or shows `ll_instructions` on absent/failed HTML.
- `values-en/strings.xml:347`–`:350` supplies generic switch/inner-notification-LED text; it has no separate generation-two local copy.
- iOS's newly bundled generation-two fallback uses the actual Astra A1 English HTML/images from the user's `aiglass_http_log_20261126_111337.txt:271`. It describes a held power button, green startup charging LED and blue pairing LED.
- The generation-two English fallback now uses the exact power-on sentence from that API HTML. The Android reference has no separate generation-two English resource to copy.
