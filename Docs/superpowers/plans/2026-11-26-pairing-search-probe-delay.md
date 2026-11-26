# Pairing search probe delay implementation plan

**Goal:** Start service verification promptly for matching advertisements without repeatedly postponing it, while keeping product-model and protocol-generation validation.

**Architecture:** Use a pure scheduling policy beside the BLE manager. Manual pairing schedules a probe once after 0.2 seconds; later advertisements keep the existing timer. Ordinary background discovery keeps its configured 1.5-second debounce. Clear the timer reference when it fires and log first advertisement, probe scheduling and list registration so future logs distinguish radio discovery from app waiting and GATT verification.

**Tech stack:** CoreBluetooth, DispatchWorkItem, existing production-source Swift probes.

**Evidence:** The supplied build-185 connection log starts L1 search at 15:46:28.342, starts its probe at 34.539 and receives AE3A services at 35.305. L2 search starts at 41.014 and its probe starts at 45.915 before log export. First advertisement times were only printed to the console and cannot be reconstructed from this log. The user confirmed that the 15:38 recording and 15:46 logs are separate reproductions. The 1.5-second cancellable timer and its per-advertisement rescheduling are confirmed in source; the logs cannot establish exactly how much of the pre-probe wait was radio discovery versus timer deferral.

## Constraints and review focus

- Local diagnosis/verification only. No independent cloud run, package or build increment.
- Retain `model_name`, `device_type`/GATT checks, UUID identity, stale-tap rejection, existing row order and user-driven binding.
- No listing of unverified protocol candidates and no changes to connection timeouts, background reconnect, or scan filters.
- A cancelled/fired timer must not block scheduling a later candidate.
- Preserve the pending single-column selection change and unrelated detail-page edit.

## Tasks

- [x] Add `PairingProbeStartPolicy.delay(isManualPairing:hasScheduledStart:defaultDelay:)` and production-source regression cases for the first candidate, repeated arrivals, cancellation/rearming and background debounce.
- [x] Integrate the policy into `scheduleProbeStart`; manual scans arm only when a candidate exists. Keep the advertised/service type admission logic unchanged.
- [x] Add bounded first-advertisement/list/probe diagnostics, extend the existing probe stand-in and verify source/probe Swift syntax and shell/Python syntax locally. First-advertisement diagnostics also retain callback-to-main-actor delay. Native execution and device timing remain pending requested packaging.

**Local validation:** Changed production methods, the scheduling enum, generated production-source probe and regression test source passed Swift parsing. Python/shell syntax and Git whitespace checks passed. Model-name, advertised/GATT generation, candidate queuing, selected UUID, cancellation and stable-row guards were compared against the baseline and retained. Six native regression assertions were added but have not executed. `analysis/search-delay-20261126/verification.json` records the checks and limits. Version remains 1.1.7 (186); no cloud run or package was started.
