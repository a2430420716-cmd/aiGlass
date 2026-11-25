# AI recording elapsed-time refresh

The supplied 16-second screen recording shows the AI Recording page, where 00:04 remains on screen before changing to 00:07. The accompanying build 183 BLE log contains one `airecord00` start at 18:35:59.868, accepted at 18:36:00.724, and one stop at 18:36:17.486. It contains recording status, not a device-supplied elapsed-time value. The log does not provide main-thread scheduling measurements or evidence of interrupted audio content.

The page constructed a new auto-connected one-second Timer publisher inside `body`. PairingCoordinator forwards BLE changes to the view; replacing that publisher can postpone the next UI tick while the elapsed-time anchor continues, producing a stale display followed by a catch-up. This is a code-level explanation consistent with the recording, not a native profiler trace.

Replace the body-created publisher with a cancellable SwiftUI task keyed only by `isRecordingUI`. Read monotonic system uptime every 250ms and update state only when the displayed whole second changes. Keep the existing device start/stop, confirmation, import, playback and page-exit behavior. This does not fabricate intermediate seconds or a device-reported duration.

Local checks passed Swift parsing, task identity/cancellation wiring, monotonic anchors, unchanged command/reset/import/player methods and version 1.1.7 (184). Evidence is in `analysis/video-timer-20261125/verification.json`. Native iOS compilation and real-device regression have not run; cloud use is reserved for user-requested packaging. No package or version change in this task.

For device validation in the next package: start AI recording immediately after glasses reconnect while initial BLE info queries continue, check 00:04 → 00:05 → 00:06 → 00:07, then stop/start again and navigate away. Confirm the task stops with the page/recording and existing audio/import behavior is retained. If the issue persists, capture UI scheduling evidence; timer changes alone cannot exclude unrelated main-thread stalls.
