# Wi-Fi guidance for glasses transfer operations

> Implement locally in this session. Keep version 1.1.7 (187) and the unrelated OTA detail view edit. No cloud task until packaging is requested.

**Goal:** Photo/video import, AI recording import and hotspot-based upgrades clearly tell the user that glasses Wi-Fi is required when no active Wi-Fi address is observed.

**Architecture:** Add a pure guidance predicate beside existing interface diagnostics, and use a shared bilingual message in the three operation managers' opening/joining status text. Use local Wi-Fi interface evidence, including IPv6, rather than the default internet path or permission-dependent SSID. The guidance is informational: existing automatic hotspot join, cancellation, bounded retries and TCP/HTTP readiness checks continue unchanged. Add actionable Wi-Fi instructions to hotspot join failures/timeouts.

**Scope:** Only operations that actually join glasses Wi-Fi. Public internet translation, BLE-only upgrades and processing already-downloaded files do not gain a Wi-Fi prerequisite. Do not claim to read the iOS Wi-Fi toggle or infer that Wi-Fi is off from a nil SSID.

- [x] Add guidance-only interface classification, covering cellular-only, connected Wi-Fi, IPv6, down/loopback interfaces and enumeration failures.
- [x] Add shared localized connection guidance and actionable join-failure copy in DeviceWifiManager.
- [x] Display guidance during hotspot opening/joining in MediaImportManager, AIRecordingImportManager and BluetoothOtaUpgradeManager.
- [x] Preserve automatic join and all transport/owner logic; verify syntax, existing test wiring, preserved source and version locally. Native tests and iOS rendering wait for requested packaging/device validation.

**UI:** Allow album/recording import status text to expand vertically for the longer Chinese/English guidance; keep the recording import button from wrapping. The guidance replaces the normal connection status only while opening/joining Wi-Fi. Existing manual-join cards continue to show the target SSID and manual recovery steps.

**Local validation:** Seven changed Swift files and the two changed DeviceWifiManager declarations parse with no Swift syntax errors. Source comparison confirms the six hotspot join/verification/readiness functions and all three operation-start functions remain unchanged. Bash syntax, Git whitespace checks and the scoped layout scan pass. Sixteen guidance/interface regression assertions were added to the existing Wi-Fi diagnostics suite and remain pending native execution. Version stays 1.1.7 (187); the unrelated OTA view hash is preserved. No cloud build, native test run or rendered iOS/device validation was performed.
