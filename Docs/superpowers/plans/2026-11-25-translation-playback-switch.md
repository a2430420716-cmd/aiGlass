# Translation playback switch correction

> Execute sequentially using the user's confirmed Android behavior. Preserve other pending changes.

**Goal:** Treat simultaneous interpretation's top-right icon as an enable/disable switch for future incoming speech, never a replay control.

**Architecture:** Remove the build 181 history buffer and replay-on-enable behavior. Retain the existing manager mute path, which cancels its player and waiting Bluetooth queue. Audio-route failure reports an error without changing or persisting a different user preference. Conversation bubble controls remain individual replay controls using the correct non-muted asset.

**Tech Stack:** SwiftUI, MainActor controller, existing PCM playback and route queue.

## Confirmed contract

- Off: incoming speech is discarded; switching off immediately stops queued and current playback.
- On: only speech arriving after enable is played. No previous recording or muted speech is replayed.
- Changing the audio route or receiving a failure callback must not silently change the switch.
- Conversation recording on the phone plays the translation on glasses; its bubble icon is a replay affordance, not a mute switch.
- Build 181 remains unchanged until packaging is requested.

## Tasks

- [x] Remove history buffering, enable-time audio routing and replay; retain future speech gating.
- [x] Keep selected preference on route/playback failure and update failure copy accordingly.
- [x] Remove obsolete history-buffer checks; add scenario checks against the production controller's actual playback methods with a recording fake output.
- [x] Run controller contract checks, remaining audio-state/PCM checks and unsigned full iOS compilation.

## Evidence

- Supplied simultaneous log is build 180: speech arrived muted at 14:42:46, input stopped at 14:42:52, enable was tapped at 14:42:53. Bluetooth A2DP output was present. This does not demonstrate a Bluetooth connection failure.
- The earlier build 179 conversation bubble referenced `android_translation_glasses_speaker`, whose file was `ic_translation_glasses_speaker_off.png`. Build 180 changed it to the non-muted asset; current source uses the corrected asset.
- User explicitly confirmed: opening the simultaneous switch plays only future new translations, matching Android.

- Native CI run `45440812328`: baseline build 181 was rejected for replaying muted speech; corrected controller scenario checks and remaining audio-state/PCM checks passed. Unsigned full iOS compilation passed. CI conclusion: success; the source payload hashes match the final workspace.
- Contract checks use production controller methods with a fake hardware output; they do not confirm sound at the physical glasses.
