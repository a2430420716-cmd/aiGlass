# Android device names and pairing model filtering implementation plan

**Goal:** Match glasses(3).zip name sources and selected-model filtering while retaining API device_type generation classification. User screenshot shows preparation content L2 while scan offers L1 0361. Do not package or change 1.1.7 (182).

**Reference:** Android SelectedDeviceModelManager.matchesDeviceName uses case-insensitive containment of raw model_name. BleSearchDialog prefers ScanRecord.deviceName, then BluetoothDevice.name; generation comes from device_type (1/2) and actual GATT services. DeviceListAdapter displays model_name_alias, falling back to model_name. BleCacheManager maps bound devices from device_name, eq_name, model_name in that order.

**Architecture:** Foundation policy resolves fresh advertised names ahead of CoreBluetooth cached names and filters by raw selected model_name, independently of generation. Apply before either direct advertisement registration or GATT probing. Retain the advertisement name until probe completion. Bound API names take precedence over legacy local aliases and raw BLE names.

**Files:** Add Bluetooth/PairingDeviceNamePolicy.swift and native tests; modify AstraA1BleManager scan/probe registration, HomeView, PairingFlow, DeviceAboutView. Existing model list and device_type decoders already match Android.

**Review focus:** Two models sharing device_type must not mix; model aliases are labels only; renamed L2/L3 names must not alter generation; stale CBPeripheral.name must not override fresh advertisement; weaker RSSI must not prevent label refresh; a different UUID must never inherit another device's name.

- [x] Pin regression cases for model filtering, fresh/cached name resolution and bound-name priority.
- [x] Apply shared name policy before scan/probe admission and preserve fresh names through service verification.
- [x] Make bound API names win over old local and live names; retain per-device identity matching.
- [ ] Run focused native checks and unsigned iOS compilation, without archive or IPA.

**Local verification:** `analysis/android-device-names-20261125/source_check.py` passed Swift syntax parsing for changed files and isolated manager methods, source integration checks for scan/probe model guards and name persistence, preservation of API/GATT generation matching, bound-name priority, Bash syntax, workflow registration, source snapshot hashes and diff whitespace. Version remains 1.1.7 (182).

**Native verification blocked:** GitHub run [45546415655](https://github.com/frankqianghe/AIGlass/actions/runs/45546415655) did not start any runner or step: "The job was not started because recent account payments have failed or your spending limit needs to be increased." Therefore the newly added native regression tests, baseline failure reproduction and complete Xcode build have not executed. Snapshot `1feefdca402548ff8dae6ed4ce3cb1c76ce179e1` matches staged source. No IPA or archive was generated.

**Server observation:** Unauthenticated model-list reads on domestic and overseas endpoints both returned application code 99 (login required). No live model mapping was assumed from the screenshot's preparation HTML. Discovery filtering uses the actual selected model_name returned to the logged-in app, exactly as Android does; model_name_alias remains only the list display label.
