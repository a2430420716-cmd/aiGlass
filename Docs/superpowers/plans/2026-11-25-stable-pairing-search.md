# Stable pairing search

**Goal:** Keep the search list visible while automatic GATT type checks run. Enter the pairing/loading presentation only after the user selects a device or binding starts. Preserve model-name and API/GATT generation checks.

**Evidence:** Build 183 recording shows searching/pairing text alternation before selection. At 17:25:10.594 the connection log enters `connecting`; at 17:25:13.287 services confirm AE3A for L1 0239 with `probing=true userPairing=false`, then scanning resumes. `PairingCoordinator.isPairingSheetConnecting` treats these background states as a user action; `DeviceSearchingSheet` hides its list whenever that property is true. Subsequent candidates repeat the same presentation. RSSI updates also re-sort existing entries while the user is selecting.

**Implementation:** Make the existing coordinator presentation gate depend on explicit user selection/binding. Keep first-discovery order within one scan while updating each device's latest display name/best RSSI in place. Extend the existing production-source scan probe with coordinator and sheet visibility properties so regression checks use actual code.

- [x] Change the presentation gate to explicit selection/binding; add native regression coverage for automatic connection phases, known-list visibility, user selection and binding.
- [x] Keep first-discovery order and in-place UUID/name/best-RSSI updates; add native order regression coverage and retain model/type mismatch cases.
- [x] Check previous/current production properties, source integration and syntax locally. Native regression execution, iOS compilation and device validation remain pending until requested packaging; no independent cloud validation is permitted.
- [x] Preserve existing unrelated OTA edits and version 1.1.7 (184). No packaging.

**User rule:** On 2026-11-25 the user required local analysis and cloud use only for packaging. The standalone cloud validation was stopped. Continue local verification; native test/compile success cannot be claimed.

**Local evidence:** `analysis/pairing-search-20261125/source_check.py` passed production/coordinator/probe Swift syntax, baseline/current source comparisons, unchanged model-name and API/GATT gates, UUID-preserving row updates, cancellation/selection guards, shell/Python syntax, version preservation and unrelated OTA hash. This is static inspection, not native Swift execution. The native regression cases are prepared for the next user-requested package.
