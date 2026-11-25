# Match Android home typography

**Goal:** Match current glasses(3).zip home text sizes, following the user's width-adaptation report and clarification. Preserve existing names, copy, colors, icons, navigation and action handling. Do not package or bump 1.1.7 (182).

**Reference:** Android fragment_home.xml uses DIMEN_36PX for the page heading, DIMEN_35PX for Capture/Record, DIMEN_28PX for feature and guide headings, DIMEN_24PX for their explanations and system volume. item_glasses.xml uses DIMEN_28PX for brand, device name and battery. values/dimens.xml converts the 720px design to 360dp, and sw resources scale it with screen width. Translate those same design pixels to iPhone logical points using width/720, keeping the minimum readable text size at 11pt. This avoids copying raw PX as points or applying one tiny fixed size to every screen.

**Implementation:** Home-scoped typography in Theme.swift; HomeView consumes the roles. Keep the shared screenTitleSize used by AlbumView unchanged. Feature/guide cards grow to fit their text, and each pair fills its row's natural height. Multiline explanations are not capped or shrunk, while Sound mode retains its requested single line. No English copy changes.

- [x] Add Android role sizes and apply to home page/device/volume/action text.
- [x] Let paired feature/guide cards grow equally for full explanations.
- [x] Check Chinese and English widths with bundled Noto Sans SC at 320/375/390/402/414/428/440pt, inspect syntax and preserve previous changes.
- [ ] Native iOS render/compilation when a Mac runner is available. Current GitHub account billing blocks runner startup; do not claim simulator or hardware validation from font measurements.

**Local verification:** `analysis/home-android-typography-20261125/check_typography.py` passed Android XML/dimension cross-checks, Swift syntax, actual bundled font measurements at ten widths (320–440pt), all feature/guide single-line heading fit thresholds, full explanation line widths, row growth configuration, Sound mode's one-line setting, and unchanged eight business actions and explanation text. At 375pt the design sizes are 14.58pt heading / 12.5pt explanation / 18.23pt media; at 402pt, 15.63 / 13.4 / 19.54pt; at 428pt, 16.64 / 14.27 / 20.81pt. Measurements predict three lines for the current English translation/vision descriptions across those representative widths. They are font-metric checks, not SwiftUI screenshots; native layout and hardware remain pending.

**Scope preserved:** Existing action callbacks, icon assets/dimensions, #5F5F5F explanation color, device-name fixes and production diagnostics policy remain. AlbumView keeps the existing shared 18pt page heading. No native unit-test suite, build, archive, IPA or version bump was performed for this UI adjustment.
