# Renamed devices must leave the previous pairing series

> Execute locally and sequentially. Preserve the unrelated OTA view edit and version 1.1.7 (187). Cloud is reserved for user-requested packaging.

**Goal:** A device advertising L2 must not remain in an L1 search due to an old CoreBluetooth name or an earlier accepted result.

**Evidence:** The supplied screenshots show 0344 listed as L1 in one search and L2 in another. They do not include UUIDs or advertisement payloads. Source has two independently reproducible gaps: missing Local Name falls back to `CBPeripheral.name`, and a nonmatching new name returns before removing the previously matching row.

**Approach:** For manual model pairing, establish identity from a nonempty Local Name observed during the current search. Retain that UUID's last actual advertised name across nameless packets, without substituting the OS cache. Record nonmatching names too, and revoke obsolete rows, queued probes and final pairing selection. Enable repeated advertisements only for manual pairing so name changes can be received. Background reconnection and protocol generation validation retain their existing behavior.

- [x] Update manual-scan name recording, stale candidate cleanup and repeated-advertisement options.
- [x] Make display registration, queued-probe admission and Pair taps recheck the current session's advertised name.
- [x] Extend production-source regression cases for cached L1/current L2, missing name packets, rename after listing, queued probes and stale taps; retain both generation contracts and stable UUID ordering.
- [x] Generate and parse production probes locally, verify diff and preserved files; record that native Swift execution and actual device broadcasts remain unverified until requested packaging/device testing.

Manual pairing will wait for a current advertised name when only a cached OS name is available. This trades an unverified early row for correct model selection. If firmware never advertises its current name, the App cannot infer the sales series from a shared generation service UUID; actual advertising behavior must then be checked with device logs.

Local checks passed: all 12 changed production methods, the generated scan probe and regression test source parse without Swift syntax errors; probe Python and runner Bash syntax checks pass; `git diff --check` passes. Comparison confirms that the standalone manual reconnect, generation classification and probe enqueue methods remain unchanged. The OTA view retains its original uncommitted hash and the version remains 1.1.7 (187).

The regression tests are prepared for the existing package workflow; they have not executed on this Windows host. No cloud task, archive or IPA was started. The screenshots do not prove which packets/UUID produced the old name, or whether the rename changed firmware advertising versus only an App alias. A clarification was requested without blocking the independently confirmed stale-name fixes.
