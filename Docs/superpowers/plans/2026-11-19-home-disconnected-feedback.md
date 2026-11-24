# Home disconnected feedback correction

> Implement in this session under the user's request to fix failed build 181 validation.

**Goal:** Tapping any of the eight home feature cards while disconnected shows exactly `设备未连接` / `Device not connected`, without entering the feature or issuing a command.

**Architecture:** Keep each action's existing first-line connection guard. Route its failure through the existing three-second toast instead of the home screen's chained system alert presentation. Host the toast on the scroll viewport, outside the disabled volume section and scrolled content. Use the entire card as its hit area. Preserve connected media busy protection and navigation behavior.

**Tech Stack:** SwiftUI, iOS 15+, native XCUITest interaction checks using the production grid/action guard/toast/style source.

## Review focus

- Disconnected card centers and empty card padding both give visible feedback.
- Bottom-row taps after scrolling still show feedback inside the screen.
- Repeated taps renew the three-second message lifetime; old dismissals do not clear a newer message.
- Chinese/English copy is exact; no navigation, commands, or sound-mode query happens when disconnected.
- Connected actions keep their original behavior, including in-flight photo/video disabling.

## Tasks

- [x] Move existing toast overlay to `scrollContent` viewport; use it from `requireConnectedDevice()`; set a rectangular card content shape in `HomeActionButtonStyle`.
- [ ] Exercise all eight production buttons through native UI taps in both languages, including scroll, repeated taps, dismissal and connected behavior. Record source extraction boundaries and device limitations.
- [x] Check Swift syntax and diff; retain build 181 unless the user asks for another package.

## Validation evidence

- Production `HomeView.swift` parses with Apple Swift frontend. The extracted production grid, all eight actions, connection guard, toast, button style and card components compile for iOS 15+.
- Native iPhone 16 simulator run `44527570565`: English taps on all eight cards passed; repeated-tap renewal and automatic dismissal passed. Connected photo/video command dispatch and connected busy capture blocking passed.
- Chinese run saw the expected toast on the first seven tapped cards, but its seventh-card width assertion ran after the three-second message expired on the slow runner. The UI helper now inspects one immutable accessibility snapshot, with Chinese rerun `44530917561` dispatched. That rerun reached its 12-minute simulator-test limit; no complete passing result is claimed. Artifact retrieval stalled, so its diagnostics are not available locally.
- The interaction target uses production source for the changed behavior. BLE hardware, device carousel, tab router and other feature destinations are fixtures. This is not a complete physical-device app test.
- CI manifest hash matches the local HomeView source. Local `git diff --check` passes. App build remains 181.
