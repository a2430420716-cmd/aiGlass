# Gen1 Recovery Target Identity Implementation Plan

**Goal:** Prevent a stored OTA UUID from selecting another pair of glasses when its current advertisement does not match the expected OTA MAC.

**Architecture:** Add a Foundation-only identity selection policy next to the existing Gen1 OTA session policy. The transport supplies the current vendor advertisement check and logs the actual match source. Persist an OTA peripheral UUID only after authentication and the existing forced-mode check, immediately before the image command.

**Tech Stack:** Swift, CoreBluetooth, Jieli RCSP SDK; existing standalone Swift regression runner.

**Spec:** User supplied 17:23 logs on November 16; bound L1 0061 and connected L1 0079 are confirmed different physical devices.

## Constraints

- Preserve cancellation/retry persistence, account and saved-image checks, transfer phases, and the direct recovery forced-mode guard.
- An expected OTA MAC must match the current advertisement even when a cached loader UUID also matches.
- Never infer device identity from name or signal strength.
- Preserve the separate pending HomeView opacity edit. No build bump or packaging requested.

## Tasks

- [x] Cover the observed saved-UUID/conflicting-MAC regression, missing manufacturer evidence, fresh matching MAC with a changed UUID, and UUID-only fallback without a saved MAC.
- [x] Integrate strict identity selection, log the real source, and defer OTA UUID persistence until authenticated feature confirmation.
- [x] Review diffs, preserve the direct forced-mode guard and check that discovery cannot persist identity; all three changed Swift files parse without errors and `git diff --check` passes. The existing CI runner includes the new regression cases.

Runtime limit: no local Swift/Xcode toolchain is available. Swift executable tests, Xcode compilation, and testing recovery with both physical devices remain pending. No cloud package was requested for this change.
