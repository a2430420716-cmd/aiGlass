# Pairing preparation and model layout implementation plan

**Goal:** Second-generation devices use their own fallback preparation text/images in English and Chinese; four selectable models fit on one phone screen.

**Architecture:** Preserve model-specific localized API HTML as the primary source. Use `device_type`-resolved generation for local fallback content, and bundle the second-generation images already referenced by the Astra A1 API instructions. Change the existing model list to two columns; preserve raw model selection, backend aliases, sorting and pairing filters.

**Tech stack:** SwiftUI, asset catalog, existing DeviceModelItem localization.

**Spec:** User confirms the wrong content is preparation steps/text/pictures. Existing `A2` response has no `en_prepare`; the fallback currently always uses the first-generation switch/inner-LED content. User requests four models visible on the selection screen.

## Constraints and review focus

- Local work only; no cloud task, package or version bump.
- `model_name` selects a product series; `device_type` selects its protocol generation. Keep display names and identifiers.
- Preserve selected-model request isolation. Refresh missing localized HTML, including missing English with present Chinese.
- Narrow screens, long aliases, absent HTML, and missing images must remain usable.

## Tasks

- [x] Replace the single model column with a two-column `LazyVGrid` in `DeviceSelectionView.swift`, bounded images and one-line fitting labels. Fetch model detail based on `localizedPrepareHTML`, not Chinese-only `prepare`.
- [x] Choose fallback steps/images by `pairingCoordinator.pairingModel.generation` in `PairingPreparationView.swift`. Add second-generation power/LED assets using the existing API images, with source documentation.
- [x] Verify downloaded images and local Swift/asset syntax. Four-card geometry fits 320x568 through larger phones; native rendering and physical-device behavior remain pending requested packaging.

## Bundled fallback image sources

These are the existing Astra A1 `en_prepare` images returned by `device/get_device_model_list`, captured in the user's `aiglass_http_log_20261126_111337.txt:271`.

- `pairing_gen2_power_on`: `https://glasses.mocoviso.com/upload/a7/35b1cd8012f7cb9df203576c78ccb9.png`
- `pairing_gen2_indicator`: `https://glasses.mocoviso.com/upload/c7/8b9078c3e7f6c5333b6d5ac4ef4ef3.png`
