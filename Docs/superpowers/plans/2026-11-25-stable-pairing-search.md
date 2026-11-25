# Stable pairing search

**Goal:** Keep the search list visible while automatic GATT type checks run. Enter the pairing/loading presentation only after the user selects a device or binding starts. Preserve model-name and API/GATT generation checks.

**Evidence:** Build 183 recording shows searching/pairing text alternation before selection. At 17:25:10.594 the connection log enters `connecting`; at 17:25:13.287 services confirm AE3A for L1 0239 with `probing=true userPairing=false`, then scanning resumes. `PairingCoordinator.isPairingSheetConnecting` treats these background states as a user action; `DeviceSearchingSheet` hides its list whenever that property is true. Subsequent candidates repeat the same presentation. RSSI updates also re-sort existing entries while the user is selecting.

**Implementation:** Make the existing coordinator presentation gate depend on explicit user selection/binding. Keep first-discovery order within one scan while updating each device's latest display name/best RSSI in place. Extend the existing production-source scan probe with coordinator and sheet visibility properties so regression checks use actual code.

- [ ] Verify background connecting/service discovery cannot hide known devices or show pairing text, while explicit selection/binding still does.
- [ ] Verify changing RSSI/name does not move rows, duplicate IDs or change selected UUID; retain existing model/type mismatch coverage.
- [ ] Demonstrate regressions against the previous source, then run updated native checks and a full unsigned iOS build on Xcode 27.1.
- [ ] Preserve existing unrelated OTA edits and version 1.1.7 (184). No packaging.
