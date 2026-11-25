# Pairing product series stays separate from protocol generation

**Goal:** Selecting a backend model such as L2 shows and pairs only devices matching that model; L1/L2/L3/M1 must not be treated as interchangeable just because `device_type` is 1. Future model names must work without adding enum cases or special branches.

**Reference:** Android `SelectedDeviceModelManager.matchesDeviceName` uses the selected raw `model_name`, case-insensitive containment against the live advertised name (cached Bluetooth name only when advertising omits a name). The API alias is for the model list. Protocol generation is a separate `device_type`/GATT decision.

**Findings:** iOS already filters scan admission and GATT probe results by raw `model_name`. The coordinator then replaces accepted scan names with a bound server/local alias, which can display another series name even when live advertising passed the selected filter. Final row registration and pairing taps also lacked an independent current-model check. The existing supplied L2 scan interval does not log an L1 admission, so it cannot establish which path produced the latest report.

**Change:** Keep the live scan name in the search sheet, filter the displayed rows by the current selected raw model, reject stale/mismatched row registration and pairing taps, and keep protocol validation separate. Existing homepage/about-device bound names remain their corresponding user names. Retain case-insensitive Android name matching for arbitrary backend model strings.

- [x] Add final current-model guards at verified registration, search presentation and selection.
- [x] Keep API/GATT generation validation, stable UUID/row order, scan cancellation and binding model unchanged.
- [x] Extend production-source regression probes with L1/L2/L3/M1, both protocol generations, stale row/name/selection cases and missing-service advertisements.
- [x] Verify source syntax/wiring and Android contract locally; native execution and device behavior remain pending requested packaging. No cloud verification, package or version bump.

**Local verification:** `analysis/pairing-series-20261125/source_check.py` passed source comparisons against the previous implementation, changed production and extracted-probe Swift parsing, Python/shell syntax, unchanged raw-model selection and API/GATT validation, homepage/settings names, version and unrelated OTA-edit preservation. Native regression cases use extracted production scan/registration/coordinator/selection code; they are prepared but have not been executed. Contract examples are illustrative local checks, not evidence of runtime Swift behavior.
