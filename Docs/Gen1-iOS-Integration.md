# First-generation glasses integration on iOS

This implementation adds the Android G5K61 first-generation protocol alongside the existing G5T71 second-generation integration. Both use the existing connection manager; the `AstraA1BleManager` class name no longer implies a second-generation-only connection.

Implementation status below describes source coverage and automated checks. No first-generation hardware has been connected or upgraded during this work.

## Device identity and transport

| Item | First generation | Second generation |
| --- | --- | --- |
| Model hints | G5K6 family, L1, Lumina L1 | G5T71, Astra A1 |
| GATT service | `AE3A` | `04000400-0000-1000-8000-009078563412` |
| Write characteristic | `AE3B` | `06000600-0000-1000-8000-009278563412` |
| Control notifications | `AE3C` | `05000500-0000-1000-8000-009178563412` |
| Voice notifications | `AE3D` | Shared second-generation notification channel |
| Control framing | `0xAA`, sender/receiver, command, big-endian payload length, CRC16-Modbus | 10-byte command name, little-endian payload length, payload |

Names only help select scan candidates. Discovered GATT services determine `DeviceGeneration`; unknown model names are not assumed to be first generation. A G5K61 connection becomes ready only after all three required characteristics are found and both control and voice notifications are enabled. API binding retains the model selected from the server and uses the iOS peripheral UUID as `serial_number`.

Source: [generation and protocol](../AIGlass/Bluetooth/Gen1/Gen1Protocol.swift), [connection manager](../AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift), [pairing](../AIGlass/PairingFlow.swift), [model classification](../AIGlass/Bluetooth/GlassDeviceModel.swift).

## Implemented paths

| Area | Coverage | Main source |
| --- | --- | --- |
| Connection | Scan aliases, service discovery, dual notifications, normal reconnect and GATT recovery, per-connection parser resets and write-queue cleanup | [AstraA1BleManager](../AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift) |
| Identity and state | Device name/model/SN, system name, Bluetooth MAC, Bluetooth and main firmware versions, battery percentage, storage, runtime status and pending media count. Charging state and its icon are Gen2-only. | [Gen1 command adapter](../AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift), [protocol parsers](../AIGlass/Bluetooth/Gen1/Gen1Protocol.swift) |
| Device controls | Photo, video start/stop, 15/60/180/300/600-second recording limits, EQ, wear detection, time sync and factory reset | [Gen1 command adapter](../AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift) |
| Tutorial | `0x81 [step, 0]` on entry and each step; only matching step with result `1` advances; step `0` exits; reconnect restores only an unfinished step on the same peripheral. `0x6A–0x6D` control the in-app guide player with per-step deduplication; exported diagnostics cover the entire guide path | [NewbieGuideView](../AIGlass/NewbieGuideView.swift), [guide diagnostics](Gen1-Newbie-Guide.md) |
| AI image recognition | `0x70` transfer, chunk assembly, window acknowledgements, missing-chunk requests, timeout handling and final length/CRC validation; preserves first-generation image orientation | [AiVisionTransferManager](../AIGlass/AiVisionTransferManager.swift) |
| AI voice | First-generation AE3D Opus framing, `0x6E` voice status and `0x69` BLE-transport wake/end events, start/data/end routing, duplicate start handling, stop draining, and no automatic second-generation resume after a reply | [AIVoiceChatManager](../AIGlass/AIVoiceChatManager.swift) |
| Translation | First-generation translation command/ACK routing, persistent Opus decoding, end-frame/timeout stop handling | [ConversationTranslationController](../AIGlass/ConversationTranslationController.swift), [SimultaneousTranslationController](../AIGlass/SimultaneousTranslationController.swift) |
| Device-triggered recording | First-generation PCM notifications recorded as 16 kHz, mono, 16-bit WAV and added to the local recording store | [Gen1AiRecordingManager](../AIGlass/Gen1AiRecordingManager.swift) |
| Album import on AP-capable firmware | Empty `0x37` opens AP and returns credentials; exact SSID and actual Wi-Fi gateway discovery; serial TCP `8556` transfer with heartbeat, durable originals, rotation, thumbnails, local recovery and optional Photos saving | [AP integration and hardware checklist](Gen1-AP-Album-Import.md) |
| First-generation video stabilization | Existing iOS PixSmart SDK with Android Gen1 parameters: `outScale=0.8`, `dregScale=240/max(width,height)`, `stdev=3`, `BT709_FULLRANGE`; preserves original audio, rotates clockwise, falls back to original on enhancement failure | [Video profile](../IOS/SXS_VideoStabilizePvDemo/videostabilization/PixSmartVideoProfile.h), [Gen1 pipeline](../AIGlass/Album/Gen1VideoImportPipeline.swift) |
| Settings and home | Shared live BLE state, per-generation capability visibility, first-generation record-duration queries and per-device response guards | [GlassesSettingsView](../AIGlass/GlassesSettingsView.swift), [HomeView](../AIGlass/HomeView.swift) |
| Bluetooth firmware OTA | Vendor JL RCSP client owns the BLE connection during OTA, then normal connection resumes and the version is re-read | [Gen1BluetoothOtaTransport](../AIGlass/Gen1BluetoothOtaTransport.swift), [BluetoothOtaUpgradeManager](../AIGlass/BluetoothOtaUpgradeManager.swift) |
| Main firmware OTA | Every update queries battery (`0x05`, ≥80%), provisions router Wi-Fi (`0x06`), then sends `0x09` HTTP download URL; `0x3A`/legacy `0x18` progress, `0x12` restart and fresh `0x15` version verification | [OTA flow and validation](Gen1-Firmware-OTA.md), [Gen1FirmwareUpdateSession](../AIGlass/Gen1FirmwareUpdateSession.swift) |

The shared command adapter rejects unsupported second-generation operations instead of writing their command bytes to first-generation `AE3B`. Switching or resetting connections clears pending writes and live setting responses.

First-generation settings hide video-resolution selection, voice-wakeup configuration and continuous-conversation duration, matching Android capabilities. EQ, wear detection, photo/video, tutorial, image recognition and translation remain available. The manual AI-recording home entry displays “Recording is not available for Gen 1 devices yet,” matching Android's explicit entry restriction; device-triggered PCM recording is a separate implemented path.

## Deliberately unavailable on iOS

| Path | Current behavior and reason |
| --- | --- |
| Album import on older Wi-Fi-Direct-only firmware | Requires an AP-capable firmware update. iOS does not provision Android's Wi-Fi Direct group; AP import uses a separate TCP path, not second-generation HTTP. |
| First-generation device recording-file import | The existing recording-file import guard remains; the new AP album flow transfers photos/videos only. Device-triggered PCM recording over BLE is separate. |
| Main firmware OTA network requirements | iOS now provisions an internet-capable router over BLE on every update. The glasses themselves download the image over HTTP; they cannot use an HTTPS-only third-party URL or an authenticated download. |
| BLE-only control of another app's music (`0x6A`–`0x6D`) | Android forwards these events through `AudioManager.dispatchMediaKeyEvent`; iOS provides no equivalent public mechanism to control arbitrary other apps. Music controls rely on the accessory's standard AVRCP implementation where the firmware emits it. Raw first-generation events remain available on `gen1ControlSubject`; global BLE-event forwarding is not implemented. |

Source: [Android first-generation transport](../app/src/main/java/com/mocoviso/glasses/utils/blue/Gen1Protocol.kt), [album import routing](../AIGlass/Album/MediaImportManager.swift), [recording-import guard](../AIGlass/AIRecordingImportManager.swift).

The Android transfer setup is in [Gen1P2pImportManager](../app/src/main/java/com/mocoviso/glasses/utils/managers/Gen1P2pImportManager.java): `WifiP2pManager`, WPS and TCP port `8556`. Its updated [firmware Wi-Fi configuration screen](../app/src/main/java/com/mocoviso/glasses/ui/activitys/FirmwareWifiConfigActivity.kt) returns Gen1 credentials to the OTA manager, which sends `0x06`. `0x17` queries Wi-Fi configuration diagnostics; it does not provision credentials.

## Bluetooth OTA SDK provenance

### Post-upgrade version confirmation (2026-10-14)

The 2026-10-10 logs show Bluetooth firmware changing from `03.26.01.06` to
`03.26.01.07`. Normal GATT became ready at `17:18:44.585`; a version query at
`17:18:45.190` received the new version at `17:18:45.264`. The former shared
90-second reconnect/query deadline could expire during the final polling sleep,
skipping an already received matching version and reporting failure at UI 95%.

- `Gen1OtaVersionVerificationSession` now gives reconnection 90 seconds and,
  after GATT becomes ready, a separate 30-second version-query window. It checks
  a received matching version before applying the timeout. Cached versions and
  transfer progress alone cannot confirm success.
- The Gen1 Bluetooth OTA recovery target protects scanning from routine
  connection/battery refreshes, including foreground entry. Pairing cancellation,
  rebinding and flow completion invalidate that recovery scope.
- A completed SDK transfer with no confirmed version ends as **Update Awaiting
  Confirmation**, rather than **Update Failed**. A fresh match ends as success;
  actual SDK errors still fail. The 95% phase represents version confirmation.
- Exported BLE logs include the attempt ID, target versions, SDK result codes,
  transfer progress, transport handoff, reconnect attempts, queries, replies and
  timeout phase. Firmware bytes and authentication packets are not logged.

Validation: 63 new version-confirmation assertions, 145 existing Gen1 main-firmware
session assertions and 1,289 shared Bluetooth/Gen2 assertions passed (1,497 total).
Final unsigned Debug device build passed. Real-device Bluetooth OTA, foreground
entry during reconnect and Gen2 upgrade smoke tests remain required.

The native implementation uses [Jieli's official iOS-JL_OTA SDK](https://github.com/Jieli-Tech/iOS-JL_OTA/tree/28f12b3dee972f110efcceb57c7dbaa5330ee085/libs/Release2.5.0), pinned to commit `28f12b3dee972f110efcceb57c7dbaa5330ee085`, release directory `libs/Release2.5.0`. The bundled `JL_OTALib`, `JL_HashPair`, `JL_AdvParse` and `JLLogHelper` frameworks include device and simulator slices; provenance and Apache 2.0 license are retained in [Frameworks/Jieli](../Frameworks/Jieli/README.md). The license is also included in the app's [resource directory](../AIGlass/ThirdPartyNotices/Jieli-OTA-LICENSE.txt).

This transport uses separate `AE00`/`AE01`/`AE02` services and characteristics, hash authentication, write backpressure and bootloader reconnect by peripheral UUID or manufacturer-advertised MAC. A completed transfer or unexpected disconnect alone is not success: the application reconnects and verifies a fresh Bluetooth firmware version. Actual G5K61 image/bootloader compatibility remains unverified.

## Validation

Completed without hardware:

- AP album update (2026-09-24): 593 first-generation assertions, including a local TCP server, and 1,289 Bluetooth/shared/second-generation regression assertions passed. Full unsigned Debug iOS device build passed. See [AP validation details](Gen1-AP-Album-Import.md).
- Video stabilization update (2026-09-24): the first-generation suite now includes 30 Gen1/Gen2 native parameter assertions and 31 video pipeline assertions, for 654 in total. Reuses the bundled iOS SDK and license; no Android binary or license is copied into iOS.
- Main firmware OTA update (2026-09-29): 1,339 first-generation assertions and 1,289 shared Bluetooth/Gen2 assertions passed. Full unsigned Debug iOS device build passed. Gen2 OTA and recovery method bodies match the pre-task baseline. Hardware OTA validation remains required; see [OTA validation](Gen1-Firmware-OTA.md).

- Standalone first-generation protocol suite: 186 assertions covering wire vectors, streaming parsers, voice routing, image assembly, metadata parsing and native WAV reading.
- Standalone command-adapter suite: 85 assertions covering Android command mappings, five recording-duration levels, ASCII Unix time, rejection of second-generation-only commands, malformed packets and sliced `Data`.
- Model routing: 11 input-name cases plus first-/second-generation image selection.
- Main-firmware update validation: 14 assertions covering HTTP URL validation, URL byte encoding and version normalization.
- Native Bluetooth OTA transport passes isolated iOS device and simulator type checking.
- Full Debug iOS device build succeeds with signing disabled, including the four Jieli frameworks.
- Changed UI/pairing files pass Swift syntax parsing; repository diff passes whitespace checking.

Run standalone suites from the repository root:

```sh
bash Tests/run-gen1-tests.sh
```

Build the app from the repository root:

```sh
xcodebuild -workspace AIGlass.xcworkspace -scheme AIGlass \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/aiglass-gen1-build CODE_SIGNING_ALLOWED=NO build
```

Device validation still required:

- G5K61/L1 scan, first pairing, binding, disconnect/reconnect, app relaunch and first-/second-generation switching.
- Both notification subscriptions and correct battery, identity, status, setting responses and tutorial acknowledgements.
- Photo/video controls, tutorial reconnect, voice recognition, translation, image chunk loss/retransmission and device-triggered recording playback.
- AP album import on updated first-generation firmware, actual hotspot gateway discovery, multiple-file transfer, BLE-only interruption and local recovery. Follow the [AP hardware checklist](Gen1-AP-Album-Import.md).
- Bluetooth OTA authentication, bootloader reconnect, progress and version verification on the actual firmware; main firmware OTA with fresh router provisioning, low battery, wrong password, timeout and reboot/version confirmation. See [Gen1 OTA hardware checks](Gen1-Firmware-OTA.md).
- Regression checks on second-generation glasses. Automated protocol checks do not establish hardware compatibility or a successful firmware upgrade.
