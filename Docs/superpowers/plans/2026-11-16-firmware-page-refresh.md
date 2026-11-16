# Firmware Page Refresh Implementation Plan

**Goal:** Refresh `user/userinfo` whenever the firmware upgrade page appears, so upgrade entries use the latest server metadata.

**Architecture:** Reuse `AuthSession.refreshUserInfo()` and its session checks and in-flight request deduplication. Recompute upgrade availability after the request and observe complete OTA dictionaries, including changes to existing versions, URLs, and release notes. Preserve BLE version queries and OTA recovery and transfer guards.

**Tech Stack:** Swift / SwiftUI.

## Tasks

- [x] Add an appearance-scoped async refresh and recompute upgrade availability when the task remains active.
- [x] Observe complete Bluetooth and firmware OTA dictionaries instead of their entry counts.
- [x] Honor task cancellation when waiting for an existing userinfo request, avoiding a cancelled sleep loop on the main actor.
- [x] Review the focused diff against pre-task working-tree snapshots, parse both changed Swift files with no syntax errors, and pass `git diff --check`.

Validation evidence: `analysis/firmware-page-refresh-20261116/validation.json` in the workspace. Existing in-flight requests remain shared; successful replies replace userinfo, and ordinary failures retain previous data under the existing AuthSession policy. OTA recovery and active-transfer metadata remain protected by the existing coordinator guards.

No build number change or packaging requested. Xcode and device validation are unavailable on this Windows host.
