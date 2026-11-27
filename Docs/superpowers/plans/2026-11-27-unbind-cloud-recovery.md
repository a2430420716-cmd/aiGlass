# Recover device-reset / cloud-unbind partial completion

**Goal:** Preserve acknowledged device resets when account unbinding times out, avoid repeated erasure, and stop the old binding from reconnecting while its cloud result is uncertain.

**Evidence:** The supplied November 27 build-187 logs show Gen2 reset result=1 at 10:23:03.395, followed by five user/unbind_device HTTP timeouts. Device-side success and cloud success were previously conflated in the UI; retries could reset the same glasses again while background reconnect kept targeting the old binding. This app change does not establish or repair the root cause of the HTTP transport failure.

**Architecture:** Persist recovery in the existing FactoryResetConfirmation source, keyed by backend origin, account ID and target UUID, with the original hardware SN and explicit offline-force permission. The coordinator reconciles fresh complete bindings before resetting/submitting. The BLE manager consults a per-target provider at normal reconnect/attach entry points. A dedicated settings continuation confirmation distinguishes partial completion from an initial destructive action.

## Implemented

- [x] After user confirmation, request fresh userinfo before any initial reset or retry. A failed/malformed/wrong-account snapshot cannot prove absence or authorize repeating the side-effecting request. Cached/coalesced refresh results and cloud connection flags are not used.
- [x] Save acknowledged reset immediately, before the cloud POST. Retry skips an acknowledged reset. Explicit offline force removal remains server-only, and never pretends that device data was erased.
- [x] Keep the pending record across process restarts, and isolate both domestic/overseas origins, accounts, UUIDs and original hardware identity. A newly confirmed bind starts a new intent and clears its matching old recovery.
- [x] If fresh bindings show absence, finish target cleanup without another reset or POST. Otherwise submit once after user-confirmed continuation; do not automatically retry POST.
- [x] Explain device-confirmed reset with cloud unbinding still unconfirmed, preserving original error details. If the initial binding check fails, explain that this attempt did not reset the device.
- [x] Pause automatic connection attempts for only the pending target; preserve saved binding, identity caches and credentials until cloud success/authoritative absence. Account/origin changes and cancelled tasks cannot clean another account/device.
- [x] On confirmed cloud success, update local cards immediately and invalidate earlier userinfo requests so a failed follow-up refresh does not keep an already-unbound device visible.
- [x] Add persistence, account/origin isolation, strict missing/malformed snapshot, physical-SN fallback and target cleanup cases to the existing device reset/identity native suite.
- [x] Validate changed Swift sources/methods, exact read-back, phase-order/ownership contracts, existing pairing fixture generation, preserved pairing admission policies and Git whitespace locally.
- [ ] Run native regression suites and app compilation during user-requested packaging.
- [ ] Verify on device: first request offline (no reset), reset ACK then cloud timeout, restart and continue, timeout-after-server-success reconciliation, original offline force retry, switching devices/accounts/regions, and explicit rebind after recovery.

## Verification limits

Local syntax and source-contract checks pass; native Swift execution, App UI rendering and hardware/server fault injection have not run on this Windows host. Unit cases are prepared in Tests/DeviceUnpairAndIdentityTests.swift, already part of the packaging workflow. No cloud job, package, build increment, server-side API call or user-data reset was performed by this local editing task. Version/build remain 1.1.7 (187); the unrelated DeviceOtaUpgradeDetailView working edit remains unchanged.
