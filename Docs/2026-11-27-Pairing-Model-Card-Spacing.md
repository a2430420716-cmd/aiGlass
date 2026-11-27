# Pairing model card spacing

The user reports that build 187's selection cards are too compact and supplies an Android/iOS comparison. Keep the single-column list and restore the Android card proportions and vertical breathing room.

Android reference: `item_lay_device.xml` uses `DIMEN_300PX` card height, `DIMEN_25PX` top spacing and `DIMEN_40PX` vertical padding. The base dimension file resolves these to 150dp, 12.5dp and 20dp on a 360dp screen (720px design grid).

`DeviceSelectionView.swift` now scales preferred card height and card spacing by container width using that same design grid. Available height can reduce the four-row card height down to 128pt; smaller screens scroll. The image/text gap grows from 4pt to 12pt, the label gap from 2pt to 5pt, and vertical content padding from 6pt to 14pt. Images can grow from 40pt to 56pt on taller screens. Existing 16pt labels, model names, API loading/sorting, selected-model callbacks and filtering stay intact.

Local verification: Swift tree-sitter parsing and `git diff --check` pass. Impeccable layout scan reports no findings. Source comparison confirms navigation and model API/name methods remain unchanged. Geometry calculations cover widths 320, 375, 390, 393 and 430pt; four rows fit geometrically at 375x667 and the taller sampled devices, while 320x568 uses scrolling. These calculations are not a native screenshot or a SwiftUI rendering test.

No Xcode/Swift compiler is available on this Windows computer. Native compilation and device appearance remain pending the next user-requested package. No cloud task or package was started; version remains 1.1.7 (187). The unrelated OTA detail view edit is preserved.
