# API device type integration plan

> Execute sequentially. Packaging remains paused by the user; preserve all existing pending changes and build 181.

**Goal:** Use `device_type` (`1`: first generation; `2`: second generation) from userinfo devices and the model list so renaming cannot change the device generation.

**Architecture:** Decode a shared typed API value, pass it through bound-device cards and selected pairing models, and use it before legacy model-name hints. Explicit invalid values remain unknown. Protocol traffic still requires the actual matching GATT service; compare the API type with that service before binding or resuming a bound connection. Search uses advertised protocol services or the existing read-only GATT service probe when API type is available.

**Tech Stack:** Codable, Foundation policies, SwiftUI model propagation, CoreBluetooth service discovery.

**Spec:** User's screenshots for `/user/userinfo` `device[]` and `/device/get_device_model_list`.

## Constraints and edge cases

- Decode numeric `1`/`2` and compatible string values. Missing/null fields retain compatibility with older responses; explicit unknown values never override themselves with a name guess.
- `device_name`, `model_name_alias`, and names such as `L2`/`L3` do not override a valid API type.
- Keep every existing display-name source: bound devices use their own `device_name`, model selection uses `model_name_alias`, and scan results use the actual peripheral's name. `device_type` never supplies a label or changes request model names.
- A detail response without `device_type` must retain the type already selected from the model list.
- Copying/renaming a home card preserves its API type; multiple devices must not share another card's type.
- A contradictory GATT service cannot receive the selected generation's commands or be bound under the wrong model.
- Metadata remains scoped to the matching UUID/SN and current account. No new request parameters are invented.

## Tasks

- [x] Add `APIDeviceType` decoding and model conversion; update both response models.
- [x] Carry the value through home cards, offline settings, selected pairing models and detail refreshes.
- [x] Search by protocol evidence for typed models; validate selected/bound API type against GATT service before connection readiness.
- [x] Cover renamed/conflicting names, mixed types, string/invalid/missing values, copied cards and detail refresh preservation in native checks.
- [x] Run targeted protocol/model tests, Swift parsing and unsigned iOS compilation; keep packaging paused.

## Verification

- GitHub Actions run `45448051857` passed: https://github.com/frankqianghe/AIGlass/actions/runs/45448051857
- Native checks: API type/name propagation 59 assertions; Gen1 protocol 205; command availability 103; GATT recovery 639; Bluetooth activation 12.
- Complete iOS Debug build with signing disabled: `BUILD SUCCEEDED`.
- All 26 changed/new Swift files and the extracted production-model probe parsed without syntax errors; `git diff --check` passed.
- Local source hashes match the verified CI snapshot. Logs saved under workspace `analysis/api-device-type-20261125/results-45448051857/`.
- No hardware pairing was performed during this validation. Packaging remains paused; build stays 181.
