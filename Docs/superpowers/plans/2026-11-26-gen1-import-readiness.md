# Gen1 import standby readiness implementation plan

**Goal:** A tap immediately after recording waits for the glasses' short shutdown instead of failing the first import. A hotspot retry must also wait through shutdown and require a stable, fresh standby report.

**Architecture:** Keep existing target/account ownership, transport, download and video processing. Share a small monotonic standby-settling gate between the preflight and the hotspot query. Bound shutdown waiting to 10 seconds; preserve rejection of recording, photo capture, unconfirmed status and unrelated operations.

**Tech stack:** Swift concurrency, Combine, existing Gen1 AP/TCP import.

**Spec:** User reports and local logs `20261126_111331` / `20261125_214238`; the former includes a successful second import with a 60.163-second final video, the latter aborts its retry at a `0x73/04` report before `0x73/00` arrives 2.4 seconds later.

## Constraints and review focus

- Local diagnosis and checks only; no cloud task or package. Keep 1.1.7 (185).
- No new media commands, recording stop, forced device state, discarded original, or unlimited retry.
- Preserve the pre-existing detail-page edit and the pending latest-version toast.
- Cancellation, device/account changes, a true busy report, and shutdown without standby must stop import.

## Tasks

- [x] Add `Gen1APImportStandbyGate.observe(_:at:)` and `isReady(at:)` in `Gen1APImportProtocol.swift`, requiring 0.75 seconds of continuous standby. Add regression sequences to `Gen1APImportTests.swift` for standby/shutdown/standby and loss of readiness.
- [x] In `MediaImportManager.swift`, wait for short shutdown before claiming import ownership; log preflight rejection so first-tap failures are diagnosable.
- [x] In `Gen1HotspotSession.swift`, wait through fresh shutdown reports within 10 seconds, then require stable fresh standby. Retain the existing three-second query/cache policy when shutdown is absent and the one-retry limit. A confirmed `04 -> 00` closure ends the credential wait early and uses that same existing retry.
- [x] Run local Swift parsing, shell syntax and diff checks; document native Swift/iOS/device checks as pending user-requested packaging.

**Validation limit:** Regression sequences are written, not executed. Windows has no Swift/Xcode runtime. The recording shows the first tap rejected before a transfer and a later successful full-length import; it does not prove every first-tap failure has the same cause. Device revalidation is required.
